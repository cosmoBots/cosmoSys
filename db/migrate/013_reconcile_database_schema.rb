require_relative '../../lib/cosmosys/migration_schema'

class ReconcileDatabaseSchema < ActiveRecord::Migration[7.2]
  include Cosmosys::MigrationSchema

  REFERENCES = [
    [:projects, :csys_ods_template_asset_id, :cosmosys_template_assets, 'fk_projects_cosmosys_ods_template'],
    [:projects, :csys_report_template_asset_id, :cosmosys_template_assets, 'fk_projects_cosmosys_report_template'],
    [:cosmosys_catalog_refs, :document_catalog_entry_id, :cosmosys_document_catalog_entries, 'fk_cosmosys_catalog_refs_entry'],
    [:cosmosys_ods_transfer_events, :ods_transfer_id, :cosmosys_ods_transfers, 'fk_cosmosys_ods_events_transfer'],
    [:cosmosys_negative_statuses, :issue_id, :issues, nil],
    [:cosmosys_negative_statuses, :issue_status_id, :issue_statuses, nil],
    [:cosmosys_presentation_baselines, :issue_id, :issues, nil]
  ].freeze

  def up
    reconcile_large_payload_capacity
    REFERENCES.each do |table, column, target, name|
      reconcile_reference_type(table, column, target, name: name)
    end

    # Retain the existing PostgreSQL lookup indexes. They are also generated
    # through Arel in the rewritten bootstrap, so fresh/updated schemas agree.
    { projects: [:cscode, 'idx_projects_lower_cscode'], issues: [:csid, 'idx_issues_lower_csid'] }.each do |table, (column, name)|
      add_index table, lower_index_expression(table, column), name: name unless index_exists?(table, name: name)
    end
  end

  def down
    # Reconciliation brings existing databases to the rewritten historical
    # contract. Do not recreate mismatched foreign-key types when rolling this
    # step back; the historical downs still remove all owned schema at zero.
  end
end
