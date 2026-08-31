require 'fileutils'
require_relative '../lib/cosmosys/ods_items'

source = Pathname(ENV.fetch('SOURCE_ODS'))
output = Pathname(ENV.fetch('OUTPUT_ODS'))

Cosmosys::OdsItems.load_rspreadsheet!
workbook = Rspreadsheet.open(source.to_s)
items = workbook.worksheets('Items') || raise('The source template has no Items sheet')
extra = workbook.worksheets('ExtraFields') || raise('The source template has no ExtraFields sheet')
dictionary = workbook.worksheets('Dict') || raise('The source template has no Dict sheet')

clear_cell = lambda do |cell|
  cell.detach_if_needed
  %w[value date-value time-value boolean-value value-type].each do |attribute|
    Rspreadsheet::Tools.remove_ns_attribute(cell.xmlnode, 'office', attribute)
  end
  Rspreadsheet::Tools.remove_ns_attribute(cell.xmlnode, 'calcext', 'value-type')
  Rspreadsheet::Tools.remove_ns_attribute(cell.xmlnode, 'table', 'formula')
  cell.xmlnode.content = ''
end

item_headers = {
  'RM#' => 'redmine_id',
  'RMID' => 'redmine_reference',
  'ID' => 'csid',
  'row#' => 'row_number',
  'Rlv?' => nil,
  'csWload' => nil
}.freeze
extra_headers = {
  'ID' => 'csid',
  'csChapter' => 'chapter',
  'csOldCode' => nil,
  'csCollab' => nil
}.freeze

obsolete_columns = Hash.new { |hash, sheet| hash[sheet] = [] }
[[items, item_headers], [extra, extra_headers]].each do |sheet, replacements|
  (1..128).each do |column|
    cell = sheet.cell(1, column)
    next unless replacements.key?(cell.value)

    replacement = replacements.fetch(cell.value)
    obsolete_columns[sheet] << column if replacement.nil?
    cell.value = replacement
  end
end

# Removing an obsolete header is not enough: the legacy cell validation and
# cached values would otherwise remain visible as an unexplained selector.
obsolete_columns.each do |sheet, columns|
  columns.each do |column|
    (1..sheet.rowcount).each do |row|
      cell = sheet.cell(row, column)
      clear_cell.call(cell)
      Rspreadsheet::Tools.remove_ns_attribute(cell.xmlnode, 'table', 'content-validation-name')
    end
  end
end

# This is a formula mirror used only to identify each ExtraFields row while
# editing. Give it a distinct name so it cannot be mistaken for a second input
# source for Items.subject.
(1..128).find { |column| %w[subject fsubject].include?(extra.cell(1, column).value.to_s) }&.then do |column|
  cell = extra.cell(1, column)
  Rspreadsheet::Tools.remove_ns_attribute(cell.xmlnode, 'table', 'formula')
  Rspreadsheet::Tools.remove_ns_attribute(cell.xmlnode, 'office', 'string-value')
  cell.value = 'fsubject'
end

# Native item fields that are intentionally round-trippable but do not belong
# in the visible planning grid live in ExtraFields. Keep this list in the base
# transformer so specialised templates inherit the same generic contract.
%w[preferred_report_diagram].each do |field|
  next if (1..128).any? { |column| extra.cell(1, column).value.to_s == field }

  column = (1..128).find { |index| extra.cell(1, index).value.to_s.empty? } || raise("No room for #{field}")
  cell = extra.cell(1, column)
  cell.value = field
  cell.format.bold = true
  cell.format.background_color = '#D9EAF7'
end

dictionary.cell(5, 1).value = 'cscode'

documents = workbook.worksheets('Documents') || workbook.add_worksheet('Documents')
catalog = workbook.worksheets('Catalog') || workbook.add_worksheet('Catalog')
document_headers = %w[redmine_id source_id project title category external_code document_date document_version description]
catalog_headers = %w[item family document sense location markdown_reference]
technical_headers = %w[row_uuid base_signature base_values]
[[documents, document_headers], [catalog, catalog_headers]].each do |sheet, headers|
  headers.each_with_index do |header, index|
    cell = sheet.cell(1, index + 1)
    cell.value = header
    cell.format.bold = true
    cell.format.background_color = '#D9EAF7'
  end
end
items.cell(1, 24).value = 'project'

control_headers = %w[row_key row_uuid base_signature base_values]
{
  'ItemsCtrl' => ['Items', 'D'],
  'DocumentsCtrl' => ['Documents', 'B'],
  'CatalogCtrl' => ['Catalog', 'F']
}.each do |name, (visible_name, visible_column)|
  control = workbook.worksheets(name) || workbook.add_worksheet(name)
  Rspreadsheet::Tools.set_ns_attribute(control.xmlnode, 'table', 'display', 'false')
  control_headers.each_with_index do |header, index|
    control.cell(1, index + 1).value = header
    control.cell(1, index + 1).format.bold = true
  end
  (2..151).each do |row|
    control.cell(row, 1).formula = %(=IF(LEN([$#{visible_name}.#{visible_column}#{row}])>0;[$#{visible_name}.#{visible_column}#{row}];""))
  end
end

# Hidden technical JSON still affects LibreOffice's optimal row height. Keep
# editable sheets free of control payloads; companion sheets carry it instead.
technical_headers.each_with_index do |_header, index|
  clear_cell.call(items.cell(1, 30 + index))
  clear_cell.call(documents.cell(1, 10 + index))
  clear_cell.call(catalog.cell(1, 7 + index))
end

# The legacy importer required LibreOffice to recalculate helper formulas before
# upload. The current reader scans until ten consecutive empty temporary IDs, so
# row counters and their MAX cells are deliberately removed.
(1..dictionary.rowcount).each do |row|
  [26, 27, 28, 29].each do |column|
    clear_cell.call(dictionary.cell(row, column))
  end
end
(1..items.rowcount).each do |row|
  [26, 28].each do |column|
    clear_cell.call(items.cell(row, column))
  end
end

# Existing exported rows receive a persisted csid from the service. Empty rows
# keep a human-editing helper that creates a temporary source ID only after a
# subject is entered, so parent and relation columns can refer to the new row.
(2..items.rowcount).each do |row|
  id_cell = items.cell(row, 4)
  id_cell.value = nil
  id_cell.formula = %(=IF(LEN([.F#{row}])>0;CONCATENATE("n";[$Dict.$B$5];ROW()-1);""))
end

(2..151).each do |row|
  document_id = documents.cell(row, 2)
  document_id.formula = %(=IF(LEN([.D#{row}])>0;CONCATENATE("d";[$Dict.$B$5];ROW()-1);""))
  markdown_reference = catalog.cell(row, 6)
  markdown_reference.formula = %(=IF(LEN([.A#{row}])>0;CONCATENATE("document:dii";ROW());""))
end

FileUtils.mkdir_p(output.dirname)
workbook.save(output.to_s)
puts "Normalized ODS export template: #{output}"
