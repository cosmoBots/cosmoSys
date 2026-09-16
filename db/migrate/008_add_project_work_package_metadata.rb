class AddProjectWorkPackageMetadata < ActiveRecord::Migration[7.2]
  def up
    add_column :projects, :csys_wp, :string unless column_exists?(:projects, :csys_wp)
    add_column :projects, :csys_wp_title, :string unless column_exists?(:projects, :csys_wp_title)
  end

  def down
    remove_column :projects, :csys_wp_title if column_exists?(:projects, :csys_wp_title)
    remove_column :projects, :csys_wp if column_exists?(:projects, :csys_wp)
  end
end
