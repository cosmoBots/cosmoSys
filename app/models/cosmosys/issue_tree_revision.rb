module Cosmosys
  class IssueTreeRevision < ActiveRecord::Base
    self.table_name = 'cosmosys_issue_tree_revisions'

    belongs_to :root_issue, class_name: 'Issue'

    validates :root_issue_id, presence: true
    validates :active, inclusion: { in: [true, false] }
    validates :root_generation, presence: true
    validates :revision, presence: true
  end
end
