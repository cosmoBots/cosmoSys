module Cosmosys
  class IssueTreeRevisionService
    def self.state_for(issue)
      new(issue).state
    end

    def self.bump_for(issue_ids)
      Issue.where(id: Array(issue_ids).compact.uniq).find_each do |issue|
        new(issue).bump!
      end
    end

    def self.bump_root!(root_issue)
      return unless root_issue

      record = ensure_root!(root_issue)
      record.with_lock do
        record.revision = record.revision.to_i + 1
        record.save!
      end
      record
    end

    def self.sync_root_membership(issue, old_root_id: nil, new_root_id: nil)
      old_root = Issue.find_by(id: old_root_id)
      new_root = Issue.find_by(id: new_root_id)

      reset_root!(old_root) if old_root && old_root.id != new_root&.id
      ensure_root!(new_root) if new_root&.parent_id.nil?
    end

    def self.ensure_root!(root_issue)
      return unless root_issue

      record = Cosmosys::IssueTreeRevision.find_or_initialize_by(root_issue_id: root_issue.id)
      if record.new_record?
        record.active = true
        record.root_generation = 1
        record.revision = 0
        record.save!
      elsif !record.active?
        record.update!(active: true, root_generation: record.root_generation.to_i + 1, revision: 0)
      elsif record.root_generation.to_i.zero?
        record.update!(active: true, root_generation: 1, revision: 0)
      end
      record
    end

    def self.reset_root!(root_issue)
      record = Cosmosys::IssueTreeRevision.find_by(root_issue_id: root_issue.id)
      return unless record

      record.update!(active: false, revision: 0)
    end

    def initialize(issue)
      @issue = issue
    end

    def state
      root_issue = current_root_issue
      record = self.class.ensure_root!(root_issue)
      { root_issue: root_issue, root_generation: record.root_generation.to_i, revision: record.revision.to_i }
    end

    def bump!
      self.class.bump_root!(current_root_issue)
    end

    private

    def current_root_issue
      @issue.root || @issue
    end
  end
end
