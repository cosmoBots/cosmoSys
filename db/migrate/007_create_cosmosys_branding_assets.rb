require_relative '../../lib/cosmosys/migration_schema'

class CreateCosmosysBrandingAssets < ActiveRecord::Migration[7.2]
  include Cosmosys::MigrationSchema
  def up
    create_table :cosmosys_branding_assets do |t|
      t.integer :project_id
      t.integer :created_by_id, null: false
      t.string :scope_key, null: false
      t.boolean :diffuse_effect, null: false, default: false
      t.timestamps null: false
    end unless table_exists?(:cosmosys_branding_assets)
    # The non-null scope_key enforces uniqueness of the instance override.
    add_index :cosmosys_branding_assets, :project_id, unique: true,
              where: index_presence_predicate(:cosmosys_branding_assets, :project_id), name: 'idx_csys_branding_project' unless index_exists?(:cosmosys_branding_assets, name: 'idx_csys_branding_project')
    add_index :cosmosys_branding_assets, :project_id, unique: true,
              where: index_presence_predicate(:cosmosys_branding_assets, :project_id, present: false), name: 'idx_csys_branding_instance' unless index_exists?(:cosmosys_branding_assets, name: 'idx_csys_branding_instance')
    add_index :cosmosys_branding_assets, :scope_key, unique: true,
              name: 'idx_csys_branding_scope' unless index_exists?(:cosmosys_branding_assets, name: 'idx_csys_branding_scope')
  end

  def down
    drop_table :cosmosys_branding_assets if table_exists?(:cosmosys_branding_assets)
  end
end
