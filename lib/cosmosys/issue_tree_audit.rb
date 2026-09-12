module Cosmosys
  class IssueTreeAudit
    def call(repair: false, user: nil)
      results = Project.where(parent_id: nil).order(:id).map do |root|
        inspect_root(root, repair: repair, user: user)
      end

      {
        checked_roots: results.length,
        checked_items: results.sum { |row| row[:items] },
        inconsistent_roots: results.count { |row| !row[:healthy] },
        repair: repair,
        results: results.reject { |row| row[:healthy] }
      }
    end

    private

    def inspect_root(root, repair:, user:)
      issues = scoped_issues(root)
      problem = Cosmosys::IssueTreeHealth.first_problem(issues)
      row = {
        root_project_id: root.id,
        root_project: root.identifier,
        items: issues.length,
        healthy: problem.nil?
      }
      return row unless problem

      row[:problem] = {
        issue_id: problem.issue.id,
        csid: problem.issue.csid,
        reason: problem.reason
      }
      if repair
        row[:repair] = Cosmosys::IssueTreeOrderRepair.new(root, user: user).call
        row[:healthy_after_repair] = Cosmosys::IssueTreeHealth.first_problem(scoped_issues(root)).nil?
      end
      row
    end

    def scoped_issues(root)
      Issue.where(project_id: root.self_and_descendants.select(:id)).order(:root_id, :lft, :id).to_a
    end
  end
end
