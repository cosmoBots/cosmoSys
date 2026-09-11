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

    private

    def visible_local_issues
      issues = Issue.visible(@user)
        .where(project_id: @project.id)
        .includes(:project, :tracker, :parent)
        .order(:csposition, :lft, :id)
        .to_a
      return issues if @include_negative

      issues_by_id = issues.index_by(&:id)
      @visible_local_issues = issues.reject do |issue|
        ancestor = issues_by_id[issue.parent_id]
        while ancestor
          break true unless ancestor.cosmosys_positive?

          ancestor = issues_by_id[ancestor.parent_id]
        end
        !issue.cosmosys_positive?
      end
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
      issue.children.visible(@user)
        .where(project_id: @project.id)
        .includes(:project, :tracker, :parent)
        .reorder(:csposition, :lft, :id)
        .to_a
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
