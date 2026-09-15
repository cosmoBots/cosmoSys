class AddCosmosysItemExternalMetadata < ActiveRecord::Migration[6.1]
  def up
    add_column :issues, :cs_ext_code, :string unless column_exists?(:issues, :cs_ext_code)
    add_column :issues, :cs_wload, :decimal, precision: 5, scale: 2 unless column_exists?(:issues, :cs_wload)
    add_index :issues, :cs_ext_code unless index_exists?(:issues, :cs_ext_code)
  end

  def down
    remove_index :issues, :cs_ext_code if index_exists?(:issues, :cs_ext_code)
    remove_column :issues, :cs_wload if column_exists?(:issues, :cs_wload)
    remove_column :issues, :cs_ext_code if column_exists?(:issues, :cs_ext_code)
  end
end
