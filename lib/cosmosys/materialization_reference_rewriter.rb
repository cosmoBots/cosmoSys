module Cosmosys
  class MaterializationReferenceRewriter
    def initialize(issues:, csid_map:, id_map:, marker_map: {})
      @issues = issues
      @replacements = csid_map.merge(marker_map).merge(id_map)
      @editorial_marker_ids = marker_map.each_with_object({}) do |(source, target), result|
        next unless source.match?(/\Adocument:di\d+\z/) && target.match?(/\Adocument:di\d+\z/)

        result[source.delete_prefix('document:')] = target.delete_prefix('document:')
      end
    end

    def call
      issues.each do |issue|
        description = rewrite_text(issue.description.to_s)
        issue.update_columns(description: description, updated_on: Time.current) if description != issue.description.to_s
        # `custom_field_values` returns Redmine's presentation wrappers, not
        # persisted ActiveRecord rows. Rewrite the stored values through the
        # association so direct column updates are available and callbacks are
        # not re-run during snapshot materialization.
        issue.custom_values.each do |value|
          next unless value.custom_field.field_format.in?(%w[string text link])

          replaced = rewrite_text(value.value.to_s)
          value.update_columns(value: replaced) if replaced != value.value.to_s
        end
      end
    end

    def rewrite_text(text)
      text = text.to_s.gsub(/(document_embed\(\s*)(di\d+)(\s*\))/) do |marker|
        target = @editorial_marker_ids[Regexp.last_match(2)]
        target ? "#{Regexp.last_match(1)}#{target}#{Regexp.last_match(3)}" : marker
      end
      replacements.sort_by { |source, _target| -source.length }.reduce(text) do |result, (source, target)|
        result.gsub(/(?<![A-Za-z0-9_-])#{Regexp.escape(source)}(?![A-Za-z0-9_-])/, target)
      end
    end

    private

    attr_reader :issues, :replacements

  end
end
