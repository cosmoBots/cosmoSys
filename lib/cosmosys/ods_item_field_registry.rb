module Cosmosys
  module OdsItemFieldRegistry
    Field = Struct.new(:name, :reader, :writer, keyword_init: true)

    module_function

    def register(name, reader: nil, writer: nil)
      key = name.to_s
      raise ArgumentError, "invalid ODS item field #{key.inspect}" unless key.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ArgumentError, "ODS item field #{key} is already registered" if fields.key?(key)

      fields[key] = Field.new(name: key, reader: reader || ->(issue) { issue.public_send(key) }, writer: writer).freeze
    end

    def names = fields.keys

    def values_for(issue)
      fields.transform_values { |field| field.reader.call(issue) }
    end

    def apply(issue, values)
      fields.each do |name, field|
        next unless values.key?(name)
        next unless field.writer

        field.writer.call(issue, values[name])
      end
    end

    def fields = (@fields ||= {})
  end
end
