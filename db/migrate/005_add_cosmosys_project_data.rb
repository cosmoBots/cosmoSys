class AddCosmosysProjectData < ActiveRecord::Migration[6.1]
  TRACKERS = {
    'cs_data' => { name: 'csData', item_profile: 'data_section' },
    'cs_datum' => { name: 'csDatum', item_profile: 'datum' }
  }.freeze

  def up
    add_column :issues, :csys_value, :text unless column_exists?(:issues, :csys_value)
    add_column :issues, :csys_datum_source_issue_id, :integer unless column_exists?(:issues, :csys_datum_source_issue_id)
    add_index :issues, :csys_datum_source_issue_id unless index_exists?(:issues, :csys_datum_source_issue_id)

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

    remove_index :issues, :csys_datum_source_issue_id if index_exists?(:issues, :csys_datum_source_issue_id)
    remove_column :issues, :csys_datum_source_issue_id if column_exists?(:issues, :csys_datum_source_issue_id)
    remove_column :issues, :csys_value if column_exists?(:issues, :csys_value)
  end

  private

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
