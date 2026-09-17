module Cosmosys
  # Scans the resolvable rich text of every visible issue in the current
  # project scope and records every successfully resolved entry in the same
  # lazy, memoized ProjectDataDictionary used by the report preview. This is
  # the "used by this project/report scope" contract for the Project data
  # viewer: it must not become a second, subtly different resolver.
  class ProjectDataScopeScanner
    def initialize(project, user:)
      @project = project
      @user = user
      @dictionary = ProjectDataDictionary.current(project: project, user: user)
    end

    def call
      visible_scope.each do |issue|
        text_attributes.each do |attribute|
          next unless issue.public_send(attribute).to_s.match?(Cosmosys::ProjectDataDictionary::EXPRESSION_PATTERN)

          @dictionary.resolve(issue.public_send(attribute))
        end
      end
      @dictionary.used_entries
    end

    private

    attr_reader :project, :user

    def visible_scope
      Issue.visible(user)
           .where(project_id: project.root.self_and_descendants.select(:id))
           .includes(:project, :tracker)
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
  end
end
