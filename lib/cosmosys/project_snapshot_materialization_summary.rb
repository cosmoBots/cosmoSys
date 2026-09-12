module Cosmosys
  class ProjectSnapshotMaterializationSummary
    def initialize(project:, plan:)
      @project = project
      @counts = plan.counts
    end

    def message
      I18n.t(
        :notice_cosmosys_project_snapshot_materialized_summary,
        project: @project.name,
        items: @counts.fetch(:items),
        documents: @counts.fetch(:documents),
        relations: @counts.fetch(:internal_relations),
        attachments: @counts.fetch(:attachments)
      )
    end
  end
end
