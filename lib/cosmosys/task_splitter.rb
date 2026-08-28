module Cosmosys
  class TaskSplitter
    Result = Struct.new(:parent, :children, keyword_init: true)

    def initialize(issue:, count:, user: User.current)
      @issue = issue
      @count = Integer(count)
      @user = user
    end

    def call
      raise ArgumentError, I18n.t(:text_cosmosys_split_count_invalid) unless (2..4).cover?(@count)
      raise ArgumentError, I18n.t(:text_cosmosys_split_not_supported) unless @issue.cosmosys_item_kind.can_split
      raise ArgumentError, I18n.t(:text_cosmosys_split_parent_forbidden) unless @issue.leaf?

      children = Issue.transaction do
        Array.new(@count) { |index| create_child!(index) }
      end
      Result.new(parent: @issue.reload, children: children)
    end

    private

    def create_child!(index)
      child = Issue.new(common_attributes)
      child.parent_issue_id = @issue.id
      child.author = @user
      if index.zero?
        child.subject = @issue.subject
        child.description = @issue.description
        child.status = @issue.status
        child.start_date = @issue.start_date
        child.due_date = @issue.due_date
        child.estimated_hours = @issue.estimated_hours
        child.done_ratio = @issue.done_ratio
        child.custom_field_values = @issue.custom_field_values.to_h { |value| [value.custom_field_id, value.value] }
      else
        child.subject = @issue.project.with_cosmosys_locale do
          I18n.t(:text_cosmosys_new_subtask_subject, number: index + 1, subject: @issue.subject)
        end
      end
      child.save!
      child
    end

    def common_attributes
      {
        project: @issue.project,
        tracker: @issue.tracker,
        priority: @issue.priority,
        assigned_to: @issue.assigned_to,
        category: @issue.category,
        fixed_version: @issue.fixed_version
      }
    end
  end
end
