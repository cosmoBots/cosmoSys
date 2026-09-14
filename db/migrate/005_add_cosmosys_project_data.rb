class AddCosmosysProjectData < ActiveRecord::Migration[6.1]
  TRACKERS = {
    'cs_data' => { name: 'csData', item_profile: 'data_section' },
    'cs_datum' => { name: 'csDatum', item_profile: 'datum' }
  }.freeze

  def up
    add_column :issues, :csys_value, :text unless column_exists?(:issues, :csys_value)
    add_column :issues, :csys_datum_source_issue_id, :integer unless column_exists?(:issues, :csys_datum_source_issue_id)
    add_index :issues, :csys_datum_source_issue_id unless index_exists?(:issues, :csys_datum_source_issue_id)

    create_negative_status_selections_table unless table_exists?(:cosmosys_negative_statuses)
    migrate_legacy_negative_status_selections

    install_trackers
  end

  def down
    TRACKERS.each_key do |key|
      tracker_id = select_value("SELECT id FROM trackers WHERE csys_key = #{connection.quote(key)}")
      next if tracker_id.blank?
      next if select_value("SELECT 1 FROM issues WHERE tracker_id = #{tracker_id} LIMIT 1")

      execute "DELETE FROM projects_trackers WHERE tracker_id = #{tracker_id}"
      execute "DELETE FROM workflows WHERE tracker_id = #{tracker_id}" if table_exists?(:workflows)
      execute "DELETE FROM trackers WHERE id = #{tracker_id}"
    end

    remove_negative_status_selections_table if table_exists?(:cosmosys_negative_statuses)

    remove_index :issues, :csys_datum_source_issue_id if index_exists?(:issues, :csys_datum_source_issue_id)
    remove_column :issues, :csys_datum_source_issue_id if column_exists?(:issues, :csys_datum_source_issue_id)
    remove_column :issues, :csys_value if column_exists?(:issues, :csys_value)
  end

  private

  def create_negative_status_selections_table
    create_table :cosmosys_negative_statuses do |t|
      t.references :issue, foreign_key: { to_table: :issues }, null: false
      t.references :issue_status, foreign_key: true, null: false
      t.timestamps null: false
    end
    add_index :cosmosys_negative_statuses, [:issue_id, :issue_status_id], unique: true, name: 'index_cosmosys_negative_statuses_on_issue_and_status'
  end

  def remove_negative_status_selections_table
    drop_table :cosmosys_negative_statuses
  end

  def migrate_legacy_negative_status_selections
    return unless column_exists?(:issues, :csys_negative_status_id)

    execute <<~SQL.squish
      INSERT INTO cosmosys_negative_statuses (issue_id, issue_status_id, created_at, updated_at)
      SELECT id, csys_negative_status_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM issues
      WHERE csys_negative_status_id IS NOT NULL
      ON CONFLICT DO NOTHING
    SQL
    execute 'UPDATE issues SET csys_negative_status_id = NULL WHERE csys_negative_status_id IS NOT NULL'
  end

  def install_trackers
    tracker_class = Class.new(ActiveRecord::Base) { self.table_name = 'trackers' }
    tracker_class.reset_column_information
    status_id = select_value('SELECT id FROM issue_statuses ORDER BY position, id LIMIT 1')
    raise 'cosmoSys project data requires at least one Redmine item status' if status_id.blank?

    TRACKERS.each do |key, definition|
      tracker = tracker_class.find_by(csys_key: key) ||
                tracker_class.where('LOWER(name) = ?', definition.fetch(:name).downcase).order(:id).first ||
                tracker_class.new
      tracker.assign_attributes(
        name: definition.fetch(:name),
        csys_key: key,
        csys_item_kind: definition.fetch(:item_profile),
        default_status_id: status_id
      )
      tracker.save!
      copy_feature_workflow(tracker.id)
      execute "INSERT INTO projects_trackers (project_id, tracker_id) SELECT id, #{tracker.id} FROM projects ON CONFLICT DO NOTHING"
    end
  end

  def copy_feature_workflow(tracker_id)
    return unless table_exists?(:workflows)

    feature_id = select_value("SELECT id FROM trackers WHERE LOWER(name) = 'feature' ORDER BY id LIMIT 1")
    return if feature_id.blank? || feature_id.to_i == tracker_id.to_i

    workflow_columns = columns(:workflows).map(&:name) - %w[id tracker_id]
    quoted_columns = workflow_columns.map { |column| connection.quote_column_name(column) }
    execute "DELETE FROM workflows WHERE tracker_id = #{tracker_id}"
    execute <<~SQL.squish
      INSERT INTO workflows (tracker_id, #{quoted_columns.join(', ')})
      SELECT #{tracker_id}, #{quoted_columns.join(', ')}
      FROM workflows
      WHERE tracker_id = #{feature_id}
    SQL
  end
end
