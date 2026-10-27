module Cosmosys
  # Schema operations shared by historical migrations and the reconciliation
  # migration for existing installations. All expressions are compiled by Arel.
  module MigrationSchema
    private

    def unqualified_attribute(table, column)
      Arel::Nodes::UnqualifiedColumn.new(Arel::Table.new(table)[column])
    end

    def lower_index_expression(table, column)
      function = Arel::Nodes::NamedFunction.new('LOWER', [unqualified_attribute(table, column)])
      Arel::Nodes::Grouping.new(function).to_sql
    end

    def index_presence_predicate(table, column, present: true)
      attribute = unqualified_attribute(table, column)
      (present ? attribute.not_eq(nil) : attribute.eq(nil)).to_sql
    end

    def reconcile_reference_type(table, column, target, name:)
      source = columns(table).find { |entry| entry.name == column.to_s }
      destination = columns(target).find { |entry| entry.name == 'id' }
      raise "Missing reference #{table}.#{column} -> #{target}.id" unless source && destination

      key = foreign_keys(table).find { |entry| entry.column.to_s == column.to_s }
      name ||= key&.name
      if source.type != destination.type || source.limit != destination.limit
        remove_foreign_key table, column: column if key
        change_column table, column, destination.type, limit: destination.limit
        key = nil
      end
      unless key
        options = { column: column }
        options[:name] = name if name
        add_foreign_key table, target, **options
      end
    end
  end
end
