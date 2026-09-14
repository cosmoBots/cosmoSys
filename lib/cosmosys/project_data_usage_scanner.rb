module Cosmosys
  class ProjectDataUsageScanner
    Usage = Struct.new(:issue, :attribute, keyword_init: true)

    def initialize(datum)
      @datum = datum
    end

    def call(limit: nil)
      return [] unless datum.project && datum.csid.present?

      matches = []
      scope.find_each do |issue|
        text_attributes.each do |attribute|
          next unless issue.public_send(attribute).to_s.match?(expression_pattern)

          matches << Usage.new(issue: issue, attribute: attribute)
          return matches if limit && matches.size >= limit
        end
      end
      matches
    end

    private

    attr_reader :datum

    def scope
      Issue.where(project_id: datum.project.root.self_and_descendants.select(:id))
           .where.not(id: datum.id)
           .select(:id, :project_id, :subject, *text_attributes)
    end

    def text_attributes
      @text_attributes ||= begin
        rich_text = IssueQuery.available_columns.filter_map do |column|
          next unless column.respond_to?(:cosmosys_report_rich_text?) && column.cosmosys_report_rich_text?

          name = column.name.to_s
          name if Issue.column_names.include?(name)
        end
        (%w[description] + rich_text).uniq.freeze
      end
    end

    def expression_pattern
      @expression_pattern ||= /\$\{#{Regexp.escape(datum.csid)}(?:\.value)?\}/i
    end
  end
end
