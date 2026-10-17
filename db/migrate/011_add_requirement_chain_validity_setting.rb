class AddRequirementChainValiditySetting < ActiveRecord::Migration[7.2]
  def up
    add_column :projects, :csys_calculate_requirement_chain_validity, :boolean,
               null: false, default: true unless column_exists?(:projects, :csys_calculate_requirement_chain_validity)
  end

  def down
    remove_column :projects, :csys_calculate_requirement_chain_validity if column_exists?(:projects, :csys_calculate_requirement_chain_validity)
  end
end
