require_relative 'ods_item_field_registry'
require_relative 'ods_row_writer'

module Cosmosys
  # Domain plugins own their accepted values, dictionary sheets and columns.
  # This developer tool prepares the shipped template. Export only populates
  # its existing catalogs; it never repairs headers, selectors or empty rows.
  class OdsTemplateService
    HEADER_SCAN_LIMIT = 128

    def self.call(workbook, first_empty_row: 2)
      new(workbook).call(first_empty_row: first_empty_row)
    end

    def self.populate_dictionaries(workbook)
      new(workbook).populate_dictionaries
    end

    def initialize(workbook)
      @workbook = workbook
      @writer = OdsRowWriter.new
    end

    def call(first_empty_row:)
      sheets = %w[Items ExtraFields].filter_map { |name| @workbook.worksheets(name) }
      locations = sheets.flat_map do |sheet|
        (1..HEADER_SCAN_LIMIT).filter_map do |column|
          name = sheet.cell(1, column).value.to_s.strip
          next if name.empty?

          attribute = OdsItemFieldRegistry.canonical_name(name)
          header = OdsItemFieldRegistry.header_for(attribute)
          @writer.cell(sheet, 1, column).value = header unless header == name
          [attribute, sheet, column]
        end
      end

      OdsItemFieldRegistry.fields.each_value do |field|
        targets = locations.select { |name, _sheet, _column| name == field.name }
        next if field.choices.nil? || targets.empty?

        dictionary = @workbook.worksheets(field.dictionary_sheet) || @workbook.add_worksheet(field.dictionary_sheet)
        populate_choices(dictionary, field, prepare: true)
        targets.each { |_name, sheet, column| bind_validation(sheet, column, field) }
      end

      selectors = %w[tracker status] + OdsItemFieldRegistry.fields.values.select(&:choices).map(&:name)
      locations.each do |name, sheet, column|
        next unless selectors.include?(name)

        (first_empty_row..sheet.rowcount).each do |row|
          cell = @writer.cell(sheet, row, column)
          cell.value = nil unless cell.value.nil? && cell.formula.to_s.empty?
        end
      end
      @workbook
    end

    def populate_dictionaries
      headers = %w[Items ExtraFields].filter_map { |name| @workbook.worksheets(name) }.flat_map do |sheet|
        (1..HEADER_SCAN_LIMIT).map { |column| sheet.cell(1, column).value.to_s.strip }
      end
      OdsItemFieldRegistry.fields.each_value do |field|
        next if field.choices.nil? || !headers.include?(field.header)

        dictionary = @workbook.worksheets(field.dictionary_sheet) || raise("ODS template has no #{field.dictionary_sheet} sheet")
        populate_choices(dictionary, field, prepare: false)
      end
      @workbook
    end

    private

    def populate_choices(sheet, field, prepare:)
      column = field.dictionary_column
      header = @writer.cell(sheet, 1, column)
      allowed_headers = prepare ? ['', field.name, field.header] : [field.header]
      unless allowed_headers.include?(header.value.to_s)
        raise "ODS #{field.dictionary_sheet} column #{column} is reserved for #{field.name}, found #{header.value.inspect}"
      end
      if prepare
        header.value = field.header
        header.format.bold = true
        header.format.background_color = '#D9EAF7'
      end
      values = Array(field.choices.respond_to?(:call) ? field.choices.call : field.choices).map(&:to_s).uniq
      raise "ODS choices for #{field.name} must not be empty" if values.empty? || values.any?(&:empty?)

      (2..[sheet.rowcount, values.length + 1].max).each do |row|
        @writer.cell(sheet, row, column).value = values[row - 2]
      end
      @choice_counts ||= {}
      @choice_counts[field.name] = values.length
    end

    def bind_validation(sheet, column, field)
      tools = Rspreadsheet::Tools
      spreadsheet = sheet.xmlnode.parent
      validations = spreadsheet.find_first('./table:content-validations')
      unless validations
        validations = tools.prepare_ns_node('table', 'content-validations')
        spreadsheet.child ? spreadsheet.child.prev = validations : spreadsheet << validations
      end
      name = "cosmosys_#{field.name}"
      previous_names = []
      validation = validations.find_first("./table:content-validation[@table:name='#{name}']")
      unless validation
        validation = tools.prepare_ns_node('table', 'content-validation')
        validations << validation
      end
      address = tools.c2a(1, field.dictionary_column).sub(/1\z/, '')
      last_row = @choice_counts.fetch(field.name) + 1
      {
        'name' => name,
        'condition' => "of:cell-content-is-in-list([$#{field.dictionary_sheet}.$#{address}$2:$#{field.dictionary_sheet}.$#{address}$#{last_row}])",
        'allow-empty-cell' => 'true',
        'display-list' => 'unsorted',
        'base-cell-address' => "#{sheet.name}.#{tools.c2a(2, column)}"
      }.each { |key, value| tools.set_ns_attribute(validation, 'table', key, value) }
      (2..sheet.rowcount).each do |row|
        cell = @writer.cell(sheet, row, column)
        previous_names << tools.get_ns_attribute_value(cell.xmlnode, 'table', 'content-validation-name', nil)
        tools.set_ns_attribute(cell.xmlnode, 'table', 'content-validation-name', name)
      end
      referenced_names = spreadsheet.find('.//*[@table:content-validation-name]').map do |node|
        tools.get_ns_attribute_value(node, 'table', 'content-validation-name', nil)
      end
      validations.find('./table:content-validation').each do |node|
        previous_name = tools.get_ns_attribute_value(node, 'table', 'name', nil)
        node.remove! if previous_names.include?(previous_name) && !referenced_names.include?(previous_name)
      end
    end
  end
end
