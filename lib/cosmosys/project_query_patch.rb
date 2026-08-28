require_dependency 'project_query'

module Cosmosys
  module ProjectQueryPatch
    def self.prepended(base)
      column = QueryColumn.new(
        :cscode,
        sortable: "#{Project.table_name}.cscode",
        caption: :label_cosmosys_project_code,
        frozen: true
      )

      unless base.available_columns.any? { |available_column| available_column.name == :cscode }
        identifier_index = base.available_columns.find_index { |available_column| available_column.name == :identifier }
        insert_at = identifier_index ? identifier_index + 1 : base.available_columns.length
        base.available_columns.insert(insert_at, column)
      end
    end

    def initialize_available_filters
      super
      add_available_filter('cscode', type: :string, name: :label_cosmosys_project_code) unless available_filters.key?('cscode')
    end

    def default_columns_names
      super.dup - [:cscode]
    end

    def columns
      cols = super.dup
      cscode_column = available_columns.find { |column| column.name == :cscode }
      return cols unless cscode_column

      cols.reject! { |column| column.name == :cscode }
      anchor_index = cols.index { |column| column.name == :identifier } || cols.index { |column| column.name == :name }

      if anchor_index
        cols.insert(anchor_index + 1, cscode_column)
      else
        cols.unshift(cscode_column)
      end

      cols
    end
  end
end
