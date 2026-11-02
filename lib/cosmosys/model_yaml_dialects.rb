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
      @dialects.fetch(profile.to_s) { raise ArgumentError, "YAML preview does not yet support project profile #{profile}" }
    end

    def self.registered?(profile) = @dialects.key?(profile.to_s)

    register('items', types: {'item' => 'normal', 'info' => 'info'})
  end
end
