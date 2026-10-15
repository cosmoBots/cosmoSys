module Cosmosys
  # Builds the same tree entries used by the project tree, rooted at one item.
  # The focus item is a virtual root and only its accessible descendants are
  # returned, so the rendered component cannot offer a drop target outside it.
  class IssueTreeFragment
    attr_reader :focus_issue, :project, :entries, :issues

    def initialize(focus_issue, user: User.current)
      @focus_issue = focus_issue
      @user = user
      @project = focus_issue.project.project_root
      @entries = []
      @issues = []
      build
    end

    def chapter_map
      @chapter_map ||= project.cosmosys_chapter_map(issues)
    end

    def project_ancestor_map
      @project_ancestor_map ||= issues.map(&:project).compact.uniq.each_with_object({}) do |item_project, map|
        map[item_project.id] = item_project.self_and_ancestors.pluck(:id)
      end
    end

    def reorderable_issue_ids
      @reorderable_issue_ids ||= issues.select do |issue|
        @user.allowed_to?(:edit_issues, issue.project)
      end.map(&:id)
    end

    private

    def build
      visible_items = Issue.visible(@user).
        where(project_id: project.self_and_descendants.select(:id)).
        includes(:project, :parent, :tracker).
        order(:csposition, :lft, :id).
        to_a.
        select { |issue| issue.cosmosys_tree_visible? && issue.cosmosys_positive? }
      children_by_parent = visible_items.group_by(&:parent_id)
      @entries = Array(children_by_parent[focus_issue.id]).map do |child|
        build_entry(child, children_by_parent)
      end
    end

    def build_entry(issue, children_by_parent)
      @issues << issue
      ProjectTreeScope::Entry.new(
        issue: issue,
        boundary: false,
        children: Array(children_by_parent[issue.id]).map { |child| build_entry(child, children_by_parent) }
      )
    end
  end
end
