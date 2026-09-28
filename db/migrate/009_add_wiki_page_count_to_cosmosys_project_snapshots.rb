class AddWikiPageCountToCosmosysProjectSnapshots < ActiveRecord::Migration[6.1]
  def up
    add_column :cosmosys_project_snapshots, :wiki_page_count, :integer, null: false, default: 0 unless column_exists?(:cosmosys_project_snapshots, :wiki_page_count)
  end
end
