require 'digest'
require 'set'

module Cosmosys
  class ApprovedPresentationBaseline
    Difference = Struct.new(:attribute_name, :baseline, :current_text, :current_sha256, keyword_init: true)
    Result = Struct.new(:inconsistent, :differences, keyword_init: true)
    ATTRIBUTES = %w[description blocking_context].freeze
    CONSOLIDATED_MATURITY_FLOOR = 1

    def self.capture!(issue, user: User.current)
      new(issue, user: user).capture!
    end

    def self.inspect(issue, user: User.current)
      new(issue, user: user).inspect
    end

    def initialize(issue, user:)
      @issue = issue
      @user = user
    end

    def capture!
      return [] unless enabled? && consolidated?

      evidence = evidence_set
      Cosmosys::PresentationBaseline.transaction do
        evidence.map do |attribute_name, value|
          normalized = normalize(value.fetch(:resolved))
          baseline = issue.cosmosys_presentation_baselines.find_or_initialize_by(attribute_name: attribute_name)
          baseline.assign_attributes(
            source_text: normalize(value.fetch(:source)),
            resolved_text: normalized,
            resolved_sha256: digest(normalized),
            ledger_json: JSON.generate(value.fetch(:ledger)),
            captured_status_id: issue.status_id,
            captured_maturity: current_maturity,
            captured_at: Time.current
          )
          baseline.save!
          baseline
        end
      end
    end

    def inspect
      return Result.new(inconsistent: false, differences: []) unless enabled?

      baselines = issue.cosmosys_presentation_baselines.where(attribute_name: ATTRIBUTES).index_by(&:attribute_name)
      active = baselines.select { |_key, baseline| current_maturity >= baseline.captured_maturity }
      return Result.new(inconsistent: false, differences: []) if active.empty?

      evidence = evidence_set
      differences = active.filter_map do |attribute_name, baseline|
        next unless comparison_visible?(baseline)

        current = normalize(evidence.fetch(attribute_name).fetch(:resolved))
        current_digest = digest(current)
        next if current_digest == baseline.resolved_sha256

        Difference.new(attribute_name: attribute_name, baseline: baseline,
                       current_text: current, current_sha256: current_digest)
      end
      Result.new(inconsistent: differences.any?, differences: differences)
    end

    private

    attr_reader :issue, :user

    def enabled?
      issue.cosmosys_item_kind.approved_presentation_baseline == true
    end

    def consolidated?
      current_maturity > CONSOLIDATED_MATURITY_FLOOR
    end

    def current_maturity
      issue.status&.cosmosys_maturity_level.to_i
    end

    def evidence_set
      system_user = User.find_by(admin: true) || user
      description, description_ledger = resolve_description(issue.description, system_user)
      {
        'description' => { source: issue.description.to_s, resolved: description, ledger: description_ledger },
        'blocking_context' => blocking_context
      }
    end

    def blocking_context
      nodes, edges = blocking_closure
      system_user = User.find_by(admin: true) || user
      dictionary = Cosmosys::ProjectDataDictionary.new(project: issue.project, user: system_user)
      source_nodes = nodes.map { |node| { 'csid' => node.csid, 'description' => normalize(node.description) } }
      resolved_nodes = nodes.map do |node|
        { 'csid' => node.csid, 'description' => normalize(dictionary.resolve(node.description)) }
      end
      {
        source: JSON.generate('nodes' => source_nodes, 'edges' => edges),
        resolved: JSON.generate('nodes' => resolved_nodes, 'edges' => edges),
        ledger: serialize_ledger(dictionary)
      }
    end

    def blocking_closure
      found = {}
      edges = Set.new
      pending = [issue]
      visited = Set.new
      until pending.empty?
        blocked = pending.shift
        next unless visited.add?(blocked.id)

        blocked.relations_to.includes(issue_from: [:project, :tracker]).where(relation_type: 'blocks').each do |relation|
          blocker = relation.issue_from
          found[blocker.id] = blocker
          edges.add([blocker.csid.to_s, blocked.csid.to_s])
          pending << blocker
        end
      end
      found.delete(issue.id)
      ordered_nodes = found.values.sort_by { |item| [item.csid.to_s.downcase, item.id] }
      ordered_edges = edges.to_a.sort_by { |from, to| [from.downcase, to.downcase] }
                           .map { |from, to| { 'from' => from, 'to' => to } }
      [ordered_nodes, ordered_edges]
    end

    def resolve_description(text, resolving_user)
      dictionary = Cosmosys::ProjectDataDictionary.new(project: issue.project, user: resolving_user)
      [dictionary.resolve(text), serialize_ledger(dictionary)]
    end

    def serialize_ledger(dictionary)
      dictionary.used_entries.map do |entry|
        { 'key' => entry.fetch(:key), 'name' => entry.fetch(:name), 'value' => entry.fetch(:value),
          'components' => entry.fetch(:components).transform_keys(&:to_s) }
      end
    end

    def comparison_visible?(baseline)
      return true if baseline.attribute_name == 'blocking_context'

      dictionary = Cosmosys::ProjectDataDictionary.new(project: issue.project, user: user)
      baseline.ledger.all? { |entry| dictionary.fetch(entry.fetch('key')).present? }
    end

    def normalize(text)
      text.to_s.gsub(/\r\n?/, "\n")
    end

    def digest(text)
      Digest::SHA256.hexdigest(text)
    end
  end
end
