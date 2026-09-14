require 'set'

module Cosmosys
  class ProjectTreeScope
    Entry = Struct.new(:issue, :boundary, :children, keyword_init: true)

    def initialize(project, user: User.current, include_negative: false)
      @project = project
      @user = user
      @include_negative = include_negative
    end

    def entries
      @entries ||= project_roots.map { |issue| build_entry(issue) }
    end

    def rendered_issues
      @rendered_issues ||= begin
        issues = []
        collect_rendered_issues(entries, issues)
        issues.uniq(&:id)
      end
    end

    def local_issues
      @local_issues ||= visible_local_issues
    end

    # Positive items whose immediate parent in the persisted tree is negative
    # (Rejected/Erased). They are excluded from the default tree/report because
    # their parent is retired, but remain fully alive and must be rescuable. In
    # the "show negatives in place" view there are no orphans: everything is
    # shown in its persisted location.
    def orphaned_roots
      return [] if @include_negative

      @orphaned_roots ||= visible_local_issues_for_scoping.values
        .select(&:cosmosys_positive?)
        .select { |issue| negative_parent?(issue) }
    end

    def orphaned_issues
      @orphaned_issues ||= orphaned_roots.map { |issue| build_entry(issue) }
    end

    private

    def visible_local_issues_for_scoping
      @visible_local_issues_for_scoping ||= Issue.visible(@user)
        .where(project_id: @project.id)
        .includes(:project, :tracker, :parent)
        .order(:csposition, :lft, :id)
        .to_a
        .select(&:cosmosys_tree_visible?)
        .index_by(&:id)
    end

    def negative_parent?(issue)
      parent = visible_local_issues_for_scoping[issue.parent_id]
      parent.present? && !parent.cosmosys_positive?
    end

    def visible_local_issues
      issues = Issue.visible(@user)
        .where(project_id: @project.id)
        .includes(:project, :tracker, :parent)
        .order(:csposition, :lft, :id)
        .to_a
        .select(&:cosmosys_tree_visible?)
      return issues if @include_negative

      issues_by_id = issues.index_by(&:id)
      @visible_local_issues = issues.reject do |issue|
        ancestor = issues_by_id[issue.parent_id]
        while ancestor
          break true unless ancestor.cosmosys_positive?

          ancestor = issues_by_id[ancestor.parent_id]
        end
        !issue.cosmosys_positive? || orphaned_in_default_view?(issue, issues_by_id)
      end
    end

    # A positive item is orphaned in the default view when its nearest ancestor
    # is negative (Rejected/Erased): it is excluded from the in-place tree/report
    # and surfaced through the virtual "orphaned items" chapter instead.
    def orphaned_in_default_view?(issue, issues_by_id)
      current = issues_by_id[issue.parent_id]
      while current
        return true unless current.cosmosys_positive?

        current = issues_by_id[current.parent_id]
      end
      false
    end

    def local_issue_ids
      @local_issue_ids ||= visible_local_issues.map(&:id).to_set
    end

    def project_roots
      @project_roots ||= visible_local_issues.filter_map do |issue|
        if issue.parent_id.blank?
          issue
        elsif local_issue_ids.include?(issue.parent_id)
          nil
        else
          boundary_parent_for(issue) || issue
        end
      end.uniq(&:id)
    end

    def build_entry(issue)
      Entry.new(
        issue: issue,
        boundary: issue.project_id != @project.id,
        children: project_visible_children(issue).map { |child| build_entry(child) }
      )
    end

    def project_visible_children(issue)
      children = issue.children.visible(@user)
        .where(project_id: @project.id)
        .includes(:project, :tracker, :parent)
        .reorder(:csposition, :lft, :id)
        .to_a
      return children if @include_negative

      children.select(&:cosmosys_positive?)
    end

    def boundary_parent_for(issue)
      parent = issue.parent
      return nil if parent.blank?
      return nil unless parent.visible?(@user)

      parent
    end

    def collect_rendered_issues(scope_entries, issues)
      scope_entries.each do |entry|
        issues << entry.issue
        collect_rendered_issues(entry.children, issues)
      end
    end
  end
end
