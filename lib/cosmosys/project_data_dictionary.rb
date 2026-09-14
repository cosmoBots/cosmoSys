module Cosmosys
  class ProjectDataRenderState < ActiveSupport::CurrentAttributes
    attribute :dictionaries
  end

  class ProjectDataDictionary
    EXPRESSION_PATTERN = /\$\{([A-Za-z][A-Za-z0-9_]*)(\.value)?\}/
    Entry = Struct.new(:key, :name, :value, :issue, keyword_init: true)
    NOT_FOUND = Object.new.freeze

    attr_reader :ledger

    def self.current(project:, user:)
      state = Cosmosys::ProjectDataRenderState
      state.dictionaries ||= {}
      identity = [project.root.id, user&.id]
      state.dictionaries[identity] ||= new(project: project, user: user)
    end

    def initialize(project:, user:)
      @project = project
      @user = user
      @cache = {}
      @ledger = {}
    end

    def resolve(text)
      text.to_s.gsub(EXPRESSION_PATTERN) do |expression|
        key = Regexp.last_match(1)
        component = Regexp.last_match(2) ? :value : :name
        entry = fetch(key)
        next expression unless entry

        replacement = component == :value ? entry.value.presence : (entry.name.presence || entry.key)
        next expression if replacement.blank?

        record(entry, component)
        block_given? ? yield(replacement.to_s, entry, component) : replacement.to_s
      end
    end

    def fetch(key)
      normalized = key.to_s.downcase
      cached = @cache.fetch(normalized) do
        @cache[normalized] = find_entry(key) || NOT_FOUND
      end
      cached.equal?(NOT_FOUND) ? nil : cached
    end

    def used_entries
      ledger.values.sort_by { |entry| entry.fetch(:key).downcase }
    end

    private

    attr_reader :project, :user

    def find_entry(key)
      profile_keys = Cosmosys::ItemKindRegistry.all.select(&:defines_project_data).map(&:key)
      issue = Issue.visible(user)
                   .joins(:tracker)
                   .where(project_id: project.root.self_and_descendants.select(:id))
                   .where(trackers: { csys_item_kind: profile_keys })
                   .where('LOWER(issues.csid) = ?', key.to_s.downcase)
                   .order(:id)
                   .first
      return unless issue

      Entry.new(key: issue.csid, name: issue.subject, value: issue.csys_value, issue: issue)
    end

    def record(entry, component)
      ledger_entry = (@ledger[entry.key.downcase] ||= {
        key: entry.key,
        name: entry.name,
        value: entry.value,
        issue: entry.issue,
        components: Hash.new(0)
      })
      ledger_entry[:components][component] += 1
    end
  end
end
