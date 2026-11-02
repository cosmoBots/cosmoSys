require 'yaml'
require 'date'
require_relative 'model_yaml_dialects'

module Cosmosys
  # Explicit, bounded draft. No selector, database lookup, callbacks or writes.
  class ModelYamlDocument
    class Invalid < ArgumentError; end
    MAX_BYTES = 1_048_576
    MAX_ITEMS = 500
    MAX_RELATIONS = 2000
    attr_reader :data, :dialect
    ROOT_KEYS = %w[format version project_profile projects items relations diagram].freeze
    ITEM_KEYS = %w[type project parent csid subject description position source_id boundary chapter closed done_ratio due_date assigned_to_id fields].freeze

    def initialize(text, expected_profile: nil)
      raise Invalid, 'YAML exceeds 1 MiB' if text.to_s.bytesize > MAX_BYTES
      syntax = Psych.parse(text.to_s)
      validate_syntax!(syntax, 0) if syntax
      @data = YAML.safe_load(text.to_s, permitted_classes: [], permitted_symbols: [], aliases: false)
      mapping!(data, 'document', ROOT_KEYS)
      raise Invalid, 'Expected format: cosmosys-model and version: 1' unless data['format'] == 'cosmosys-model' && data['version'] == 1
      profile = data['project_profile']
      raise Invalid, 'Unknown project_profile' unless profile.is_a?(String) && ProjectProfileRegistry.registered?(profile)
      raise Invalid, "Document profile #{profile} differs from project profile #{expected_profile}" if expected_profile && profile != expected_profile
      @dialect = ModelYamlDialects.fetch(profile)
      validate_projects!
      validate_items!
      validate_relations!
      validate_diagram!
    rescue Psych::Exception, TypeError, KeyError, ArgumentError => error
      raise Invalid, error.message
    end

    def profile = data.fetch('project_profile')
    def projects = data.fetch('projects')
    def items = data.fetch('items')
    def relations = data.fetch('relations', [])

    private

    def mapping!(value, location, allowed = nil)
      raise Invalid, "#{location} must be a mapping with string keys" unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }
      unknown = value.keys - allowed if allowed
      raise Invalid, "#{location}: unknown fields #{unknown.join(', ')}" if unknown&.any?
    end

    def validate_syntax!(node, depth)
      raise Invalid, 'YAML nesting exceeds 64 levels' if depth > 64
      if node.is_a?(Psych::Nodes::Mapping)
        keys = node.children.each_slice(2).map(&:first)
        raise Invalid, 'Complex YAML keys are not supported' unless keys.all? { |key| key.is_a?(Psych::Nodes::Scalar) }
        values = keys.map(&:value)
        raise Invalid, 'Duplicate YAML keys are not allowed' unless values.uniq.size == values.size
        raise Invalid, 'YAML merge keys are not supported' if values.include?('<<')
      end
      Array(node.children).each { |child| validate_syntax!(child, depth + 1) }
    end

    def validate_projects!
      mapping!(projects, 'projects')
      raise Invalid, 'Declare between 1 and 50 projects' unless projects.size.between?(1, 50)
      projects.each do |key, row|
        identifier!(key)
        mapping!(row, "project #{key}", %w[name cscode parent])
        raise Invalid, "project #{key}: name is required" unless row['name'].is_a?(String) && !row['name'].strip.empty?
        raise Invalid, "project #{key}: cscode must be alphanumeric text" if row.key?('cscode') && !(row['cscode'].is_a?(String) && row['cscode'].match?(/\A[a-zA-Z0-9]+\z/))
        raise Invalid, "project #{key}: unknown parent" if row.key?('parent') && !projects.key?(row['parent'])
      end
      no_cycles!(projects, 'project')
    end

    def validate_items!
      mapping!(items, 'items')
      raise Invalid, "Declare between 1 and #{MAX_ITEMS} items" unless items.size.between?(1, MAX_ITEMS)
      source_ids = []; csids = []
      items.each do |key, row|
        identifier!(key)
        mapping!(row, "item #{key}", ITEM_KEYS)
        kind = dialect.types[row['type']]
        raise Invalid, "item #{key}: unknown type #{row['type'].inspect}" unless kind && ItemKindRegistry.registered?(kind)
        raise Invalid, "item #{key}: unknown project" unless projects.key?(row['project'])
        raise Invalid, "item #{key}: subject must be text" unless row['subject'].is_a?(String) && !row['subject'].strip.empty?
        raise Invalid, "item #{key}: description must be text" if row.key?('description') && !row['description'].is_a?(String)
        raise Invalid, "item #{key}: unknown parent" if row.key?('parent') && !items.key?(row['parent'])
        %w[closed boundary].each { |field| raise Invalid, "item #{key}: #{field} must be boolean" if row.key?(field) && ![true, false].include?(row[field]) }
        %w[source_id position assigned_to_id].each do |field|
          next unless row.key?(field)
          raise Invalid, "item #{key}: invalid #{field}" unless row[field].is_a?(Integer) && row[field].between?(1, 2_147_483_647)
        end
        raise Invalid, "item #{key}: invalid done_ratio" if row.key?('done_ratio') && !(row['done_ratio'].is_a?(Integer) && row['done_ratio'].between?(0, 100))
        if row.key?('due_date')
          raise Invalid, "item #{key}: due_date must be YYYY-MM-DD text" unless row['due_date'].is_a?(String) && row['due_date'].match?(/\A\d{4}-\d{2}-\d{2}\z/)
          Date.iso8601(row['due_date'])
        end
        %w[csid chapter].each { |field| raise Invalid, "item #{key}: #{field} must be text" if row.key?(field) && !row[field].is_a?(String) }
        csids << row['csid'].downcase if row['csid']
        source_ids << row['source_id'] if row['source_id']
        mapping!(row.fetch('fields', {}), "item #{key} fields", dialect.fields.keys)
        dialect.validate_item&.call(row)
      end
      raise Invalid, 'Duplicate csid' unless csids.uniq.size == csids.size
      raise Invalid, 'Duplicate source_id' unless source_ids.uniq.size == source_ids.size
      no_cycles!(items, 'item')
      items.each do |key, row|
        next unless row['parent']
        parent = items.fetch(row['parent'])
        kind = ItemKindRegistry.fetch(dialect.types.fetch(row['type']))
        parent_kind = ItemKindRegistry.fetch(dialect.types.fetch(parent['type']))
        unless parent_kind.can_have_children != false && (kind.allowed_parent_profiles.nil? || kind.allowed_parent_profiles.include?(parent_kind.key)) &&
               (parent_kind.allowed_child_profiles.nil? || parent_kind.allowed_child_profiles.include?(kind.key))
          raise Invalid, "item #{key}: parent/child profile combination is not allowed"
        end
      end
    end

    def validate_relations!
      raise Invalid, "relations must be a list of at most #{MAX_RELATIONS}" unless relations.is_a?(Array) && relations.size <= MAX_RELATIONS
      seen = []
      relations.each do |row|
        mapping!(row, 'relation', %w[from to type delay])
        raise Invalid, 'Relation endpoints must be declared in items' unless items.key?(row['from']) && items.key?(row['to'])
        raise Invalid, 'Unsupported relation type' unless %w[blocks precedes relates].include?(row['type'])
        raise Invalid, 'Self relations are not allowed' if row['from'] == row['to']
        raise Invalid, 'Relation delay must be an integer' if row.key?('delay') && !row['delay'].is_a?(Integer)
        identity = row.values_at('from', 'to', 'type')
        raise Invalid, 'Duplicate relation' if seen.include?(identity)
        seen << identity
        dialect.validate_relation&.call(row, items)
      end
    end

    def validate_diagram!
      options = data.fetch('diagram', {})
      mapping!(options, 'diagram', %w[rankdir layout container_policy])
      raise Invalid, 'Unsupported rankdir' if options['rankdir'] && !%w[TB LR].include?(options['rankdir'])
      raise Invalid, 'Only dot layout is supported in this first preview' if options['layout'] && options['layout'] != 'dot'
      if options['container_policy'] && !%w[all_containers related_only].include?(options['container_policy'])
        raise Invalid, 'Unsupported container_policy'
      end
    end

    def no_cycles!(rows, label)
      rows.each_key do |key|
        seen = []; current = key
        while current
          raise Invalid, "#{label} hierarchy has a cycle or exceeds 64 levels" if seen.include?(current) || seen.size >= 64
          seen << current
          current = rows.fetch(current)['parent']
        end
      end
    end

    def identifier!(key)
      raise Invalid, "Invalid local key #{key.inspect}" unless key.match?(/\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*\z/) && key.length <= 128
    end
  end
end
