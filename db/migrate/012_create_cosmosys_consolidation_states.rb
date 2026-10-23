class CreateCosmosysConsolidationStates < ActiveRecord::Migration[7.2]
  def up
    unless table_exists?(:cosmosys_consolidation_states)
      create_table :cosmosys_consolidation_states do |t|
        t.string :consolidator_key, null: false
        t.string :scope_key, null: false
        t.string :fingerprint, null: false, limit: 64
        t.timestamps null: false
      end
    end
    add_index :cosmosys_consolidation_states, [:consolidator_key, :scope_key],
              unique: true, name: 'idx_cosmosys_consolidations_key_scope' unless
      index_exists?(:cosmosys_consolidation_states, [:consolidator_key, :scope_key], unique: true,
                    name: 'idx_cosmosys_consolidations_key_scope')

  end

  def down
    # Consolidated project-tracker assignments are retained; only the
    # optimization state is removed.
    drop_table :cosmosys_consolidation_states if table_exists?(:cosmosys_consolidation_states)
  end
end
