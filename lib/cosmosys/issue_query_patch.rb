require_dependency 'issue_query'

module Cosmosys
  module IssueQueryPatch
    def self.prepended(base)
      column = QueryColumn.new(
        :csid,
        sortable: "#{Issue.table_name}.csid",
        caption: :label_cosmosys_csid,
        frozen: true
      )

      unless base.available_columns.any? { |available_column| available_column.name == :csid }
        id_index = base.available_columns.find_index { |available_column| available_column.name == :id }
        insert_at = id_index ? id_index + 1 : base.available_columns.length
        base.available_columns.insert(insert_at, column)
      end
    end

    def initialize_available_filters
      super
      add_available_filter('csid', type: :string, name: :label_cosmosys_csid) unless available_filters.key?('csid')
    end

    def default_columns_names
      names = project.present? ? project.cosmosys_item_list_column_names.map(&:to_sym) : []
      (names.presence || super.dup) - [:csid]
    end

    def columns
      cols = super.dup
      csid_column = available_columns.find { |column| column.name == :csid }
      return cols unless csid_column

      cols.reject! { |column| column.name == :csid }
      anchor_index = cols.index { |column| column.name == :id }

      if anchor_index
        cols.insert(anchor_index + 1, csid_column)
      else
        cols.unshift(csid_column)
      end

      cols
    end
  end
end
