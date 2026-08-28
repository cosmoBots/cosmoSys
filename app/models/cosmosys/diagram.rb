module Cosmosys
  class Diagram < ActiveRecord::Base
    self.table_name = 'cosmosys_diagrams'

    STATES = %w[obsolete ready].freeze

    belongs_to :issue, optional: true
    belongs_to :project, optional: true

    validates :kind, presence: true
    validates :state, presence: true, inclusion: { in: STATES }
    validates :root_generation, presence: true
    validates :tree_revision, presence: true
    validate :single_diagram_scope

    private

    def single_diagram_scope
      if issue_id.blank? && project_id.blank?
        errors.add(:base, 'diagram must belong to an issue or a project')
      elsif issue_id.present? && project_id.present?
        errors.add(:base, 'diagram cannot belong to an issue and a project at the same time')
      end
    end
  end
end
