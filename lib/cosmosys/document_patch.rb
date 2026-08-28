require_dependency 'document'

module Cosmosys
  module DocumentPatch
    def self.included(base)
      base.class_eval do
        has_many :cosmosys_document_catalog_entries,
                 class_name: 'Cosmosys::DocumentCatalogEntry',
                 foreign_key: :document_id,
                 inverse_of: :document,
                 dependent: :destroy
        validates :external_code, length: { maximum: 255 }
        validates :cosmosys_document_version, length: { maximum: 255 }
        before_destroy :cosmosys_prevent_referenced_document_destroy, prepend: true
        safe_attributes 'external_code', 'cosmosys_document_date', 'cosmosys_document_version'
      end

      searchable_columns = Array(base.searchable_options[:columns]).dup
      base.searchable_options = base.searchable_options.merge(
        columns: searchable_columns | ["#{base.table_name}.external_code", "#{base.table_name}.cosmosys_document_version"]
      )
    end

    def cosmosys_search_label
      [title, external_code.presence, cosmosys_document_version.presence].compact.join(' — ')
    end

    private

    def cosmosys_prevent_referenced_document_destroy
      return unless cosmosys_document_catalog_entries.joins(:catalog_refs).exists?

      errors.add(:base, I18n.t(:error_cosmosys_document_referenced))
      throw :abort
    end
  end
end
