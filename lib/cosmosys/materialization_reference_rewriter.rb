module Cosmosys
  class MaterializationReferenceRewriter
    def initialize(issues:, csid_map:, id_map:, marker_map: {})
      @issues = issues
      @replacements = csid_map.merge(marker_map).merge(id_map)
    end

    def call
      issues.each do |issue|
        description = replace_tokens(issue.description.to_s)
        issue.update_columns(description: description, updated_on: Time.current) if description != issue.description.to_s
        issue.custom_field_values.each do |value|
          next unless value.custom_field.field_format.in?(%w[string text link])

          replaced = replace_tokens(value.value.to_s)
          value.update_columns(value: replaced) if replaced != value.value.to_s
        end
      end
    end

    private

    attr_reader :issues, :replacements

    def replace_tokens(text)
      replacements.sort_by { |source, _target| -source.length }.reduce(text) do |result, (source, target)|
        result.gsub(/(?<![A-Za-z0-9_-])#{Regexp.escape(source)}(?![A-Za-z0-9_-])/, target)
      end
    end
  end
end
