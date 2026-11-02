module Cosmosys
  module OdsItemFieldRegistry
    Field = Struct.new(:name, :header, :reader, :writer, :deferred, :remapper, :choices, :dictionary_sheet, :dictionary_column, keyword_init: true)

    module_function

    def register(name, header: nil, reader: nil, writer: nil, deferred: false, remapper: nil,
                 choices: nil, dictionary_sheet: nil, dictionary_column: nil)
      key = name.to_s
      raise ArgumentError, "invalid ODS item field #{key.inspect}" unless key.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ArgumentError, "ODS item field #{key} is already registered" if fields.key?(key)
      header = (header || key).to_s
      raise ArgumentError, "invalid ODS item header #{header.inspect}" unless header.match?(/\A[a-z][a-z0-9_]*\z/)
      if fields.values.any? { |field| [field.name, field.header].include?(header) || field.header == key }
        raise ArgumentError, "ODS item header #{header} is already registered"
      end
      if choices || dictionary_sheet || dictionary_column
        unless choices && dictionary_sheet.to_s.match?(/\ADict[A-Za-z][A-Za-z0-9_]*\z/) &&
               dictionary_column.is_a?(Integer) && dictionary_column.positive?
          raise ArgumentError, 'ODS choices require a plugin dictionary sheet (Dict...) and a positive column'
        end
        if fields.values.any? { |field| field.dictionary_sheet == dictionary_sheet && field.dictionary_column == dictionary_column }
          raise ArgumentError, "ODS dictionary #{dictionary_sheet} column #{dictionary_column} is already registered"
        end
      end

      fields[key] = Field.new(name: key, header: header, reader: reader || ->(issue) { issue.public_send(key) },
                              writer: writer, deferred: deferred, remapper: remapper,
                              choices: choices, dictionary_sheet: dictionary_sheet, dictionary_column: dictionary_column).freeze
    end

    def names = fields.keys

    def canonical_name(header)
      fields.values.find { |field| field.header == header }&.name || header
    end

    def header_for(name) = fields[name]&.header || name

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
