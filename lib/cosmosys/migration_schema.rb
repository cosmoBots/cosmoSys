module Cosmosys
  # Schema operations shared by historical migrations and the reconciliation
  # migration for existing installations. All expressions are compiled by Arel.
  module MigrationSchema
    # 16 MiB minus one byte selects medium-sized text/blob storage where the
    # adapter has bounded types, without exceeding PostgreSQL's text limit.
    # This is schema capacity, not preallocated space or an upload-size policy.
    # Existing wider/unbounded columns are never narrowed by reconciliation.
    LARGE_PAYLOAD_LIMIT = 16_777_215

    LARGE_PAYLOAD_COLUMNS = {
      issues: %i[csys_value],
      cosmosys_diagrams: %i[svg_body dot_body],
      cosmosys_ods_transfers: %i[summary_json file_data result_data],
      cosmosys_ods_transfer_events: %i[message details_json],
      cosmosys_project_snapshots: %i[manifest_gzip],
      cosmosys_presentation_baselines: %i[source_text resolved_text ledger_json]
    }.freeze

    private

    def reconcile_large_payload_capacity
      LARGE_PAYLOAD_COLUMNS.each do |table, names|
        names.each do |name|
          column = columns(table).find { |entry| entry.name == name.to_s }
          raise "Missing payload column #{table}.#{name}" unless column
          next if column.limit.nil? || column.limit >= LARGE_PAYLOAD_LIMIT

          change_column table, name, column.type, limit: LARGE_PAYLOAD_LIMIT
        end
      end
    end

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
