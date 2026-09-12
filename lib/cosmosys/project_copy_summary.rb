module Cosmosys
  class ProjectCopySummary
    def initialize(context)
      @context = context
      @summary = context.summary
    end

    def message
      external = @summary.fetch(:external_relations, {})
      reconciliation = @summary.fetch(:pending_relation_reconciliation, {})
      I18n.t(
        :notice_cosmosys_project_copy_complete,
        project: @context.destination_project.name,
        items: @summary.fetch(:items, 0),
        documents: @summary.fetch(:documents, 0),
        references: @summary.fetch(:catalog_refs, 0),
        retained: count(external, 'retain_original'),
        remapped: count(external, 'remap_by_csid'),
        pending: count(external, 'pending'),
        resolved: count(reconciliation, :resolved)
      )
    end

    private

    def count(hash, key)
      (hash[key] || hash[key.to_s] || hash[key.to_sym]).to_i
    end
  end
end
