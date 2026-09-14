module Cosmosys
  class ProjectDataReconciliation
    POLICIES = %w[cancel keep overwrite].freeze

    attr_reader :entries, :policy

    def initialize(rows:, root:, policy: nil, user: User.current)
      @rows = rows
      @root = root
      @user = user
      @policy = POLICIES.include?(policy.to_s) ? policy.to_s : 'cancel'
      @entries = build_entries
    end

    def matches
      entries.select { |entry| entry.fetch(:status) == 'match' }
    end

    def conflicts
      entries.select { |entry| entry.fetch(:status) == 'conflict' }
    end

    def blocking?
      conflicts.any? && policy == 'cancel'
    end

    private

    attr_reader :rows, :root, :user

    def build_entries
      return [] unless root

      data_rows = rows.select { |row| data_profile?(row.dig('tracker', 'item_profile')) }
      existing = existing_by_key(data_rows.filter_map { |row| row['csid'] })
      data_rows.filter_map do |row|
        target = existing[row.fetch('csid').downcase]
        next unless target

        source_value = row.fetch('profile_fields', {})['csys_value'].to_s
        status = target.subject.to_s == row.fetch('subject').to_s && target.csys_value.to_s == source_value ? 'match' : 'conflict'
        visible = Issue.visible(user).where(id: target.id).exists?
        {
          source_key: row.fetch('key'), key: row.fetch('csid'), status: status,
          source_name: row.fetch('subject').to_s, source_value: source_value,
          target_id: target.id, target_visible: visible,
          target_name: visible ? target.subject.to_s : nil,
          target_value: visible ? target.csys_value.to_s : nil
        }
      end
    end

    def data_profile?(key)
      Cosmosys::ItemKindRegistry.fetch(key).defines_project_data == true
    end

    def existing_by_key(keys)
      normalized = keys.map { |key| key.to_s.downcase }.uniq
      return {} if normalized.empty?

      profile_keys = Cosmosys::ItemKindRegistry.all.select(&:defines_project_data).map(&:key)
      Issue.joins(:tracker)
           .where(project_id: root.self_and_descendants.select(:id), trackers: { csys_item_kind: profile_keys })
           .where('LOWER(issues.csid) IN (?)', normalized)
           .index_by { |issue| issue.csid.downcase }
    end
  end
end
