module Cosmosys
  class RelatedItemsCreator
    OPERATIONS = %w[successors predecessors blocked blockers related].freeze
    Result = Struct.new(:source, :issues, :relations, keyword_init: true)

    def initialize(source:, count:, operation:, tracker: nil, restricted: false, user: User.current,
                   issue_attributes: {}, subject_builder: nil)
      @source = source
      @count = Integer(count)
      @operation = operation.to_s
      @tracker = tracker || source.tracker
      @restricted = ActiveModel::Type::Boolean.new.cast(restricted)
      @user = user
      @issue_attributes = issue_attributes.to_h.symbolize_keys
      @subject_builder = subject_builder
    end

    def call
      raise ArgumentError, I18n.t(:text_cosmosys_related_count_invalid) unless (1..4).cover?(@count)
      raise ArgumentError, I18n.t(:text_cosmosys_related_operation_invalid) unless OPERATIONS.include?(@operation)
      raise ArgumentError, I18n.t(:text_cosmosys_restricted_requires_precedence) if @restricted && !%w[successors predecessors].include?(@operation)
      raise ArgumentError, I18n.t(:text_cosmosys_tracker_not_enabled) unless @source.project.trackers.include?(@tracker)

      issues = []
      relations = []
      Issue.transaction do
        @count.times do |index|
          issue = build_issue(index)
          issue.save!
          issues << issue
          relations << create_relation!(issue)
        end
      end
      Result.new(source: @source, issues: issues, relations: relations)
    end

    private

    def build_issue(index)
      issue = Issue.new(
        project: @source.project,
        tracker: @tracker,
        priority: @source.priority,
        assigned_to: @source.assigned_to,
        category: @source.category,
        fixed_version: @source.fixed_version,
        parent_issue_id: @source.parent_issue_id,
        author: @user,
        subject: related_subject(index)
      )
      issue.assign_attributes(@issue_attributes)
      issue
    end

    def related_subject(index)
      @source.project.with_cosmosys_locale do
        if @subject_builder
          @subject_builder.call(@source, index)
        else
          I18n.t(:text_cosmosys_new_related_subject, number: index + 1, subject: @source.subject)
        end
      end
    end

    def create_relation!(issue)
      from, to, type = relation_tuple(issue)
      IssueRelation.create!(issue_from: from, issue_to: to, relation_type: type, cosmosys_restricted: @restricted)
    end

    def relation_tuple(issue)
      case @operation
      when 'successors' then [@source, issue, IssueRelation::TYPE_PRECEDES]
      when 'predecessors' then [issue, @source, IssueRelation::TYPE_PRECEDES]
      when 'blocked' then [@source, issue, IssueRelation::TYPE_BLOCKS]
      when 'blockers' then [issue, @source, IssueRelation::TYPE_BLOCKS]
      else [@source, issue, IssueRelation::TYPE_RELATES]
      end
    end
  end
end
