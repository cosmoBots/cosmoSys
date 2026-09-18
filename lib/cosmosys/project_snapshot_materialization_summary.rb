module Cosmosys
  class ProjectSnapshotMaterializationSummary
    def initialize(project:, plan:)
      @project = project
      @counts = plan.counts
      @restored_external_relations = plan.external_relation_reconciliation.count do |entry|
        entry.fetch(:classification) == 'resolved'
      end
    end

    def message
      I18n.t(
        :notice_cosmosys_project_snapshot_materialized_summary,
        project: @project.name,
        items: @counts.fetch(:items),
        documents: @counts.fetch(:documents),
        wiki_pages: @counts.fetch(:wiki_pages),
        relations: @counts.fetch(:internal_relations) + @restored_external_relations,
        attachments: @counts.fetch(:attachments)
      )
    end
  end
end
