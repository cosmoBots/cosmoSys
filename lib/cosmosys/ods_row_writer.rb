module Cosmosys
  # Materializes each ODF row and cell once, then keeps direct XML-backed
  # proxies for the duration of an export. Rspreadsheet's regular random
  # access deliberately resolves repeated ODF nodes on every call; that is a
  # safe fallback, but becomes expensive for wide templates and many rows.
  class OdsRowWriter
    def initialize
      @rows = {}
      @cells = {}
    end

    def cell(sheet, row_index, column_index)
      key = [sheet.object_id, row_index.to_i, column_index.to_i]
      @cells[key] ||= materialize_cell(sheet, row_index.to_i, column_index.to_i)
    end

    private

    def materialize_row(sheet, row_index)
      key = [sheet.object_id, row_index]
      @rows[key] ||= begin
        row = sheet.row(row_index)
        row.detach_if_needed
        node = row.xmlnode
        row.define_singleton_method(:xmlnode) { node }
        row
      end
    end

    def materialize_cell(sheet, row_index, column_index)
      row = materialize_row(sheet, row_index)
      cell = row.cell(column_index)
      cell.detach_if_needed
      node = cell.xmlnode
      cell.define_singleton_method(:xmlnode) { node }
      cell
    end
  end
end
