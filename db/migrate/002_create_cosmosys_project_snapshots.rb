class CreateCosmosysProjectSnapshots < ActiveRecord::Migration[6.1]
  def up
    unless table_exists?(:cosmosys_project_snapshots)
      create_table :cosmosys_project_snapshots do |t|
        t.integer :project_id, null: false
        t.integer :created_by_id, null: false
        t.string :schema_version, null: false
        t.string :content_sha256, null: false
        t.string :name
        t.binary :manifest_gzip, null: false
        t.integer :item_count, null: false, default: 0
        t.integer :document_count, null: false, default: 0
        t.integer :relation_count, null: false, default: 0
        t.timestamps null: false
      end
    end

    add_index :cosmosys_project_snapshots, [:project_id, :created_at], name: 'idx_cosmosys_project_snapshots_history' unless index_exists?(:cosmosys_project_snapshots, [:project_id, :created_at], name: 'idx_cosmosys_project_snapshots_history')
    add_index :cosmosys_project_snapshots, :content_sha256 unless index_exists?(:cosmosys_project_snapshots, :content_sha256)

    unless table_exists?(:cosmosys_pending_relations)
      create_table :cosmosys_pending_relations do |t|
        t.integer :root_project_id, null: false
        t.integer :local_issue_id, null: false
        t.string :external_csid, null: false
        t.string :relation_type, null: false
        t.string :local_side, null: false
        t.integer :delay
        t.integer :source_relation_id
        t.integer :resolved_relation_id
        t.string :status, null: false, default: 'pending'
        t.timestamps null: false
      end
    end
    add_index :cosmosys_pending_relations, [:root_project_id, :status], name: 'idx_csys_pending_rel_root_status' unless index_exists?(:cosmosys_pending_relations, [:root_project_id, :status], name: 'idx_csys_pending_rel_root_status')
    add_index :cosmosys_pending_relations, [:root_project_id, :external_csid], name: 'idx_csys_pending_rel_root_csid' unless index_exists?(:cosmosys_pending_relations, [:root_project_id, :external_csid], name: 'idx_csys_pending_rel_root_csid')
    add_index :cosmosys_pending_relations, [:local_issue_id, :external_csid, :relation_type, :local_side], unique: true, name: 'idx_csys_pending_rel_identity' unless index_exists?(:cosmosys_pending_relations, [:local_issue_id, :external_csid, :relation_type, :local_side], name: 'idx_csys_pending_rel_identity')
  end

  def down
    drop_table :cosmosys_pending_relations if table_exists?(:cosmosys_pending_relations)
    remove_index :cosmosys_project_snapshots, :content_sha256 if index_exists?(:cosmosys_project_snapshots, :content_sha256)
    remove_index :cosmosys_project_snapshots, name: 'idx_cosmosys_project_snapshots_history' if index_exists?(:cosmosys_project_snapshots, name: 'idx_cosmosys_project_snapshots_history')
    drop_table :cosmosys_project_snapshots if table_exists?(:cosmosys_project_snapshots)
  end
end
