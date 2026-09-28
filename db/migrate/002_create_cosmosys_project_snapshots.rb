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
  end

  def down
    remove_index :cosmosys_project_snapshots, :content_sha256 if index_exists?(:cosmosys_project_snapshots, :content_sha256)
    remove_index :cosmosys_project_snapshots, name: 'idx_cosmosys_project_snapshots_history' if index_exists?(:cosmosys_project_snapshots, name: 'idx_cosmosys_project_snapshots_history')
    drop_table :cosmosys_project_snapshots if table_exists?(:cosmosys_project_snapshots)
  end
end
