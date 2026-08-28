module Cosmosys
  module DocumentReferenceDiagramSupport
    private

    def visible_document_references_for(issues)
      issue_ids = Array(issues).map(&:id).compact.uniq
      return [] if issue_ids.empty?

      Cosmosys::CatalogRef.where(issue_id: issue_ids)
                          .includes(:issue, document_catalog_entry: :document)
                          .to_a
                          .select { |catalog_ref| catalog_ref.visible?(User.current) }
                          .sort_by do |catalog_ref|
        entry = catalog_ref.document_catalog_entry
        [entry.family, entry.position, entry.id, catalog_ref.id]
      end
    end
  end
end
