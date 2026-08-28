module Cosmosys
  class DocumentCatalogEntry < ActiveRecord::Base
    self.table_name = 'cosmosys_document_catalog_entries'

    FAMILIES = %w[R A C].freeze
    LABEL_PREFIXES = { 'R' => 'RD', 'A' => 'AD', 'C' => 'CD' }.freeze

    belongs_to :project
    belongs_to :document
    has_many :catalog_refs,
             class_name: 'Cosmosys::CatalogRef',
             foreign_key: :document_catalog_entry_id,
             inverse_of: :document_catalog_entry,
             dependent: :destroy

    validates :project, :document, :family, :position, presence: true
    validates :family, inclusion: { in: FAMILIES }
    validates :document_id, uniqueness: { scope: :family }
    validate :document_belongs_to_project

    scope :ordered, -> { order(:position, :id) }

    def catalog_label
      index = self.class.where(project_id: project_id, family: family)
                        .where('position < ? OR (position = ? AND id <= ?)', position, position, id)
                        .count
      "#{LABEL_PREFIXES.fetch(family)}.#{index}"
    end

    def self.find_or_create_for!(document:, family:)
      transaction do
        entry = lock.find_by(document_id: document.id, family: family)
        entry || create!(
          project: document.project,
          document: document,
          family: family,
          position: where(project_id: document.project_id, family: family).maximum(:position).to_i + 1
        )
      end
    rescue ActiveRecord::RecordNotUnique
      find_by!(document_id: document.id, family: family)
    end

    def move_to!(new_position)
      siblings = self.class.where(project_id: project_id, family: family).ordered.to_a
      siblings.delete_if { |entry| entry.id == id }
      target = [[new_position.to_i, 1].max, siblings.length + 1].min
      siblings.insert(target - 1, self)
      self.class.transaction do
        siblings.each_with_index { |entry, index| entry.update_columns(position: index + 1, updated_at: Time.current) }
      end
    end

    def self.compact!(project_id:, family:)
      transaction do
        where(project_id: project_id, family: family).ordered.each_with_index do |entry, index|
          entry.update_columns(position: index + 1, updated_at: Time.current) unless entry.position == index + 1
        end
      end
    end

    private

    def document_belongs_to_project
      return if document.nil? || project_id == document.project_id

      errors.add(:document, :invalid)
    end
  end
end
