module Cosmosys
  class PendingRelation < ActiveRecord::Base
    self.table_name = 'cosmosys_pending_relations'

    belongs_to :root_project, class_name: 'Project'
    belongs_to :local_issue, class_name: 'Issue'
    belongs_to :resolved_relation, class_name: 'IssueRelation', optional: true

    validates :external_csid, :relation_type, presence: true
    validates :local_side, inclusion: { in: %w[from to] }
    validates :status, inclusion: { in: %w[pending resolved] }

    scope :pending, -> { where(status: 'pending') }
  end
end
