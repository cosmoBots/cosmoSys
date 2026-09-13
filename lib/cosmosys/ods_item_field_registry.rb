module Cosmosys
  module OdsItemFieldRegistry
    Field = Struct.new(:name, :reader, :writer, :deferred, :remapper, keyword_init: true)

    module_function

    def register(name, reader: nil, writer: nil, deferred: false, remapper: nil)
      key = name.to_s
      raise ArgumentError, "invalid ODS item field #{key.inspect}" unless key.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ArgumentError, "ODS item field #{key} is already registered" if fields.key?(key)

      fields[key] = Field.new(name: key, reader: reader || ->(issue) { issue.public_send(key) },
                              writer: writer, deferred: deferred, remapper: remapper).freeze
    end

    def names = fields.keys

    def values_for(issue)
      fields.transform_values { |field| field.reader.call(issue) }
    end

    def apply(issue, values, phase: :all, context: {})
      fields.each do |name, field|
        next unless values.key?(name)
        next unless field.writer
        next if phase == :immediate && field.deferred
        next if phase == :deferred && !field.deferred

        value = field.remapper ? field.remapper.call(values[name], context) : values[name]
        field.writer.call(issue, value)
      end
    end

    def fields = (@fields ||= {})
  end
end
