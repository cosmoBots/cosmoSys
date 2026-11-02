module Cosmosys
  # Extensions own their vocabulary and fields. Core owns the document format.
  module ModelYamlDialects
    Dialect = Struct.new(:types, :fields, :validate_item, :validate_relation, keyword_init: true)
    @dialects = {}

    def self.register(profile, types:, fields: {}, validate_item: nil, validate_relation: nil)
      @dialects[profile.to_s] = Dialect.new(types: types.freeze, fields: fields.freeze,
        validate_item: validate_item, validate_relation: validate_relation).freeze
    end

    def self.fetch(profile)
      raise ArgumentError, "Unknown project profile #{profile}" unless registered?(profile)

      extension = @dialects[profile.to_s]
      types = ItemKindRegistry.all.to_h { |kind| [kind.key, kind.key] }.merge(extension&.types || {})
      # Reuse the plugin allowlist, never its persistence writers or computed
      # readers: drafts may only assign native scalar attributes.
      fields = {}
      if defined?(OdsItemFieldRegistry)
        OdsItemFieldRegistry.names.each do |name|
          fields[name] = name if Issue.attribute_types.key?(name)
        end
      end
      fields.merge!(extension&.fields || {})
      adapters = @dialects.filter_map do |key, adapter|
        [ProjectProfileRegistry.fetch(key).provider, adapter] if ProjectProfileRegistry.registered?(key)
      end
      provider_for = ->(row) { ItemKindRegistry.fetch(types.fetch(row.fetch('type'))).provider }
      Dialect.new(types: types.freeze, fields: fields.freeze,
        validate_item: lambda do |row|
          adapters.each { |provider, adapter| adapter.validate_item&.call(row) if provider == provider_for.call(row) }
        end,
        validate_relation: lambda do |row, items|
          providers = [provider_for.call(items.fetch(row.fetch('from'))), provider_for.call(items.fetch(row.fetch('to')))]
          adapters.each { |provider, adapter| adapter.validate_relation&.call(row, items) if providers.include?(provider) }
        end).freeze
    end

    def self.registered?(profile) = ProjectProfileRegistry.registered?(profile)

    register('items', types: {'item' => 'normal', 'info' => 'info'})
  end
end
