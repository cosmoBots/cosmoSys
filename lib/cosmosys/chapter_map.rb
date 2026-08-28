module Cosmosys
  class ChapterMap
    def self.for_issues(issues)
      new(issues).map
    end

    def self.for_project(project, issues = nil)
      scope = issues || Issue.where(project_id: project.self_and_descendants.select(:id)).includes(:parent)
      new(scope).map
    end

    def self.for_subtree(issue, issues = nil)
      base_chapter = for_issue(issue)
      return {} if base_chapter.blank?

      scope =
        if issues
          issue_ids = Array(issues).map(&:id)
          Issue.where(id: issue_ids).select { |candidate| candidate.id == issue.id || candidate.is_descendant_of?(issue) }
        else
          [issue] + issue.descendants.to_a
        end

      new(scope).map.transform_values do |local_chapter|
        [base_chapter, local_chapter.split('.').drop(1)].flatten.compact.join('.')
      end
    end

    def self.for_issue(issue)
      return nil unless issue

      path = []
      current = issue

      while current.present?
        sibling_ids = sibling_scope_for(current).reorder(:lft, :id).pluck(:id)
        sibling_index = sibling_ids.index(current.id)
        return nil unless sibling_index

        path << (sibling_index + 1).to_s
        current = current.parent
      end

      path.reverse.join('.')
    end

    def initialize(issues)
      @issues = Array(issues).compact
      @children_by_parent_id = @issues.group_by(&:parent_id)
    end

    def map
      @map ||= begin
        result = {}
        assign_children(nil, nil, result)
        result
      end
    end

    private

    def assign_children(parent_id, prefix, result)
      ordered_children(parent_id).each_with_index do |issue, index|
        chapter = [prefix, index + 1].compact.join('.')
        result[issue.id] = chapter
        assign_children(issue.id, chapter, result)
      end
    end

    def ordered_children(parent_id)
      Array(@children_by_parent_id[parent_id]).sort_by do |issue|
        [issue.csposition || 0, issue.lft || 0, issue.id]
      end
    end

    def self.sibling_scope_for(issue)
      if issue.parent_id.present?
        issue.parent.children.reorder(:csposition, :lft, :id)
      else
        Issue.where(project_id: issue.project_id, parent_id: nil).reorder(:csposition, :lft, :id)
      end
    end
  end
end
