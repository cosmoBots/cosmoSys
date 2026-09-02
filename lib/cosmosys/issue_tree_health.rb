require 'set'

module Cosmosys
  class IssueTreeHealth
    Problem = Struct.new(:issue, :reason, keyword_init: true)

    def self.first_problem(issues)
      new(Array(issues)).first_problem
    end

    def self.problem_for_issue(issue)
      return if issue.blank?

      new([issue]).problem_for(issue)
    end

    def initialize(issues)
      @issues = issues.compact
      @issues_by_id = @issues.index_by(&:id)
      @root_ids = @issues.map(&:root_id).compact.uniq
      @root_issues = Issue.where(id: @root_ids).index_by(&:id)
      @duplicate_lft = duplicate_values_for(:lft)
      @duplicate_rgt = duplicate_values_for(:rgt)
      @position_problem_by_issue_id = position_problems
    end

    def first_problem
      @issues.each do |issue|
        problem = problem_for(issue)
        return problem if problem
      end

      nil
    end

    def problem_for(issue)
      return @position_problem_by_issue_id[issue.id] if @position_problem_by_issue_id.key?(issue.id)
      return Problem.new(issue: issue, reason: :missing_nested_set_values) if issue.root_id.blank? || issue.lft.blank? || issue.rgt.blank?
      return Problem.new(issue: issue, reason: :invalid_nested_set_interval) if issue.lft >= issue.rgt
      return Problem.new(issue: issue, reason: :duplicate_lft) if @duplicate_lft.include?([issue.root_id, issue.lft])
      return Problem.new(issue: issue, reason: :duplicate_rgt) if @duplicate_rgt.include?([issue.root_id, issue.rgt])

      root_issue = @root_issues[issue.root_id]
      return Problem.new(issue: issue, reason: :missing_root_issue) if root_issue.blank?
      if issue.root? && issue.root_id != issue.id
        return Problem.new(issue: issue, reason: :root_id_mismatch)
      end

      if issue.parent_id.present?
        parent_issue = @issues_by_id[issue.parent_id] || Issue.find_by(id: issue.parent_id)
        return Problem.new(issue: issue, reason: :missing_parent_issue) if parent_issue.blank?
        return Problem.new(issue: issue, reason: :parent_root_mismatch) if parent_issue.root_id != issue.root_id
        return Problem.new(issue: issue, reason: :parent_bounds_invalid) unless parent_issue.lft < issue.lft && parent_issue.rgt > issue.rgt
      end

      nil
    end

    private

    def position_problems
      family_keys = @issues.map { |issue| sibling_family_key(issue) }.uniq.to_set
      parent_ids = @issues.filter_map(&:parent_id).uniq
      root_project_ids = @issues.select { |issue| issue.parent_id.blank? }.map(&:project_id).uniq
      complete_issues = []
      complete_issues.concat(Issue.where(parent_id: parent_ids).to_a) if parent_ids.any?
      complete_issues.concat(Issue.where(project_id: root_project_ids, parent_id: nil).to_a) if root_project_ids.any?
      complete_families = complete_issues.group_by { |issue| sibling_family_key(issue) }
                                         .select { |family, _siblings| family_keys.include?(family) }

      complete_families.each_with_object({}) do |(_family, siblings), problems|
        positions = siblings.map { |issue| issue.csposition.to_i }
        reason =
          if positions.any? { |position| position <= 0 }
            :invalid_sibling_position
          elsif positions.uniq.length != positions.length
            :duplicate_sibling_position
          elsif positions.sort != (1..positions.length).to_a
            :missing_sibling_position
          end
        if reason
          representative = siblings.min_by { |issue| [issue.csposition.to_i, issue.lft.to_i, issue.id] }
          problems[representative.id] = Problem.new(issue: representative, reason: reason)
        end
      end
    end

    def sibling_family_key(issue)
      issue.parent_id.present? ? [:parent, issue.parent_id] : [:project_roots, issue.project_id]
    end

    def duplicate_values_for(column)
      @issues.
        reject { |issue| issue.root_id.blank? || issue.public_send(column).blank? }.
        group_by { |issue| [issue.root_id, issue.public_send(column)] }.
        select { |_key, issues| issues.size > 1 }.
        keys.
        to_set
    end
  end
end
