module Cosmosys
  class ReportPlaceholder < ActiveRecord::Base
    self.table_name = 'cosmosys_report_placeholders'

    KINDS = {
      'reference_documents' => 'R',
      'applicable_documents' => 'A',
      'compliance_documents' => 'C'
    }.freeze

    belongs_to :issue
    belongs_to :project

    validates :issue, :project, :kind, presence: true
    validates :issue_id, uniqueness: true
    validates :kind, inclusion: { in: KINDS.keys }, uniqueness: { scope: :project_id }
    validate :issue_belongs_to_project
    validate :item_profile_allows_kind

    def family
      KINDS.fetch(kind)
    end

    private

    def issue_belongs_to_project
      return if issue.nil? || project.nil? || issue.project_id == project_id

      errors.add(:issue, :invalid)
    end

    def item_profile_allows_kind
      return if issue.nil? || issue.cosmosys_item_kind.report_placeholder_kinds.to_a.include?(kind)

      errors.add(:kind, :inclusion)
    end
  end
end
