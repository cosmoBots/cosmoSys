module Cosmosys
  class CatalogRef < ActiveRecord::Base
    self.table_name = 'cosmosys_catalog_refs'

    belongs_to :document_catalog_entry,
               class_name: 'Cosmosys::DocumentCatalogEntry',
               inverse_of: :catalog_refs
    belongs_to :issue

    delegate :document, :document_id, :project, :project_id, :family, :catalog_label, to: :document_catalog_entry

    validates :document_catalog_entry, :issue, presence: true
    validates :sense, :location, length: { maximum: 255 }
    validate :issue_belongs_to_project
    before_destroy :ensure_not_mentioned_by_issue
    after_destroy :remove_empty_catalog_entry

    scope :ordered, -> { order(:id) }

    def markdown_reference
      "document:di#{id}"
    end

    def visible?(user = User.current)
      issue.visible?(user) && document.visible?(user)
    end

    def restricted_document?(user = User.current)
      issue.visible?(user) && !document.visible?(user)
    end

    def editable?(user = User.current)
      issue.editable?(user) && user.allowed_to?(:view_documents, project)
    end

    def destroy_from_issue!
      @skip_text_reference_guard = true
      destroy!
    ensure
      @skip_text_reference_guard = false
    end

    private

    def issue_belongs_to_project
      return if issue.nil? || document_catalog_entry.nil? || issue.project_id == project.id

      errors.add(:issue, :invalid)
    end

    def ensure_not_mentioned_by_issue
      return if @skip_text_reference_guard

      marker = markdown_reference
      values = [issue.description]
      issue.custom_field_values.each do |value|
        values << value.value if value.custom_field.field_format.in?(%w[string text link])
      end
      return unless values.flatten.compact.any? { |value| value.to_s.include?(marker) }

      errors.add(:base, I18n.t(:error_cosmosys_catalog_ref_in_use, reference: marker))
      throw :abort
    end

    def remove_empty_catalog_entry
      entry = document_catalog_entry
      return if entry.nil? || entry.catalog_refs.exists?

      project_id = entry.project_id
      family = entry.family
      entry.destroy!
      Cosmosys::DocumentCatalogEntry.compact!(project_id: project_id, family: family)
    end
  end
end
