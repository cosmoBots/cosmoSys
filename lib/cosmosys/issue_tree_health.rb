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
      @issues.group_by { |issue| [issue.project_id, issue.parent_id] }.each_with_object({}) do |(_family, siblings), problems|
        ordered = siblings.sort_by { |issue| [issue.lft.to_i, issue.id] }
        positions = ordered.map { |issue| issue.csposition.to_i }
        reason =
          if positions.any? { |position| position <= 0 }
            :invalid_sibling_position
          elsif positions.uniq.length != positions.length
            :duplicate_sibling_position
          elsif positions.sort != (1..positions.length).to_a
            :missing_sibling_position
          elsif positions != (1..positions.length).to_a
            :sibling_order_mismatch
          end
        problems[ordered.first.id] = Problem.new(issue: ordered.first, reason: reason) if reason
      end
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
