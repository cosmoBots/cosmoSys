module Cosmosys
  class IssueTreeOrderRepair
    def initialize(project, user: User.current)
      @project = project
      @user = user
    end

    def call
      result = { families: 0, items: 0 }
      Issue.transaction do
        issues = scope.lock.to_a
        return result unless Cosmosys::IssueTreeHealth.first_problem(issues)

        root_ids = issues.map(&:root_id).compact.uniq
        root_ids.each { |root_id| Issue.rebuild_single_tree!(root_id) }
        issues = scope.reload.to_a
        issues.group_by { |issue| sibling_family_key(issue) }.each_value do |siblings|
          positions = siblings.map { |issue| issue.csposition.to_i }
          next if positions.sort == (1..positions.length).to_a

          ordered = siblings.sort_by { |issue| [issue.csposition.to_i, issue.lft.to_i, issue.id] }
          changed = ordered.each_with_index.count do |issue, index|
            next false if issue.csposition == index + 1

            issue.update_column(:csposition, index + 1)
            true
          end
          next if changed.zero?

          result[:families] += 1
          result[:items] += changed
        end
      end
      Rails.logger.info({ cosmosys_maintenance: 'tree_order_repair', project_id: @project.id,
                          user_id: @user.id, families: result[:families], items: result[:items] }.to_json)
      result
    end

    private

    def scope
      Issue.where(project_id: @project.project_root.self_and_descendants.select(:id)).order(:root_id, :lft, :id)
    end

    def sibling_family_key(issue)
      issue.parent_id.present? ? [:parent, issue.parent_id] : [:project_roots, issue.project_id]
    end
  end
end
