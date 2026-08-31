module Cosmosys
  class SiblingOrder
    def self.append(issue)
      siblings = sibling_scope(issue).where.not(id: issue.id)
      next_position = siblings.maximum(:csposition).to_i + 1
      issue.csposition = next_position if issue.csposition.blank?
    end

    def self.move_before(issue, target_issue)
      move_relative(issue, target_issue, :before)
    end

    def self.move_after(issue, target_issue)
      move_relative(issue, target_issue, :after)
    end

    def self.normalize!(scope)
      scope.reorder(:csposition, :id).each.with_index(1) do |issue, index|
        next if issue.csposition == index

        issue.update_column(:csposition, index)
      end
    end

    def self.apply_order!(issues)
      Array(issues).each.with_index(1) do |issue, index|
        next if issue.csposition == index

        issue.update_column(:csposition, index)
      end
    end

    def self.align_with_tree!(scope)
      apply_order!(scope.reorder(:lft, :id).to_a)
    end

    def self.sibling_scope(issue)
      if issue.parent_id.present?
        Issue.where(parent_id: issue.parent_id)
      else
        Issue.where(project_id: issue.project_id, parent_id: nil)
      end
    end

    def self.move_relative(issue, target_issue, direction)
      raise ArgumentError, 'target required' unless target_issue

      if target_issue.parent_id.blank? && issue.project_id != target_issue.project_id
        issue.errors.add(:base, I18n.t(:text_cosmosys_invalid_parent_scope))
        return issue
      end

      issue.parent_issue_id = target_issue.parent_id
      return issue unless issue.valid?

      append(issue) if issue.csposition.blank?

      scope = sibling_scope(target_issue).where.not(id: issue.id).reorder(:csposition, :id).to_a
      insert_index = scope.index { |candidate| candidate.id == target_issue.id } || scope.length
      insert_index += 1 if direction == :after
      reordered = scope.dup
      reordered.insert(insert_index, issue)

      Issue.transaction do
        reordered.each_with_index do |candidate, index|
          next_position = index + 1
          if candidate.id == issue.id
            issue.csposition = next_position
          elsif candidate.csposition != next_position
            candidate.update_column(:csposition, next_position)
          end
        end
      end
    end
  end
end
