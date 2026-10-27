class CreateCosmosysBrandingAssets < ActiveRecord::Migration[7.2]
  def up
    return if table_exists?(:cosmosys_branding_assets)

    create_table :cosmosys_branding_assets do |t|
      t.integer :project_id
      t.integer :created_by_id, null: false
      t.string :scope_key, null: false
      t.boolean :diffuse_effect, null: false, default: false
      t.timestamps null: false
    end
    # Nullable unique keys allow independent project overrides. The non-null
    # scope_key below enforces uniqueness of the instance-wide override too.
    add_index :cosmosys_branding_assets, :project_id, unique: true,
              name: 'idx_csys_branding_project'
    add_index :cosmosys_branding_assets, :scope_key, unique: true,
              name: 'idx_csys_branding_scope'
  end

  def down
    drop_table :cosmosys_branding_assets if table_exists?(:cosmosys_branding_assets)
  end
end
