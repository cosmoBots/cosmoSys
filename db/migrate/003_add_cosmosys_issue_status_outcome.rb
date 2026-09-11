class AddCosmosysIssueStatusOutcome < ActiveRecord::Migration[6.1]
  OUTCOMES_BY_NAME = {
    'approved' => 'successful',
    'closed' => 'successful',
    'rejected' => 'unsuccessful',
    'erased' => 'unsuccessful'
  }.freeze

  def up
    add_column :issue_statuses, :csys_closed_outcome, :string unless column_exists?(:issue_statuses, :csys_closed_outcome)
    add_index :issue_statuses, :csys_closed_outcome unless index_exists?(:issue_statuses, :csys_closed_outcome)
    add_column :trackers, :csys_negative_status_ids, :text unless column_exists?(:trackers, :csys_negative_status_ids)

    OUTCOMES_BY_NAME.each do |name, outcome|
      execute <<~SQL.squish
        UPDATE issue_statuses
        SET csys_closed_outcome = #{connection.quote(outcome)}
        WHERE LOWER(name) = #{connection.quote(name)} AND is_closed = #{connection.quoted_true}
      SQL
    end

    install_negative_tracker
  end

  private

  def install_negative_tracker
    tracker_class = Class.new(ActiveRecord::Base) { self.table_name = 'trackers' }
    tracker_class.reset_column_information
    status_id = select_value('SELECT id FROM issue_statuses ORDER BY position, id LIMIT 1')
    return if status_id.blank?

    tracker = tracker_class.find_by(csys_key: 'cs_negative') || tracker_class.new
    tracker.assign_attributes(
      name: 'csNegative',
      csys_key: 'cs_negative',
      csys_item_kind: 'negative',
      default_status_id: status_id
    )
    tracker.save!
    execute "INSERT INTO projects_trackers (project_id, tracker_id) SELECT id, #{tracker.id} FROM projects ON CONFLICT DO NOTHING"
  end

  def down
    tracker_id = select_value("SELECT id FROM trackers WHERE csys_key = 'cs_negative'")
    if tracker_id.present?
      execute "DELETE FROM projects_trackers WHERE tracker_id = #{tracker_id}"
      execute "DELETE FROM trackers WHERE id = #{tracker_id}"
    end
    remove_index :issue_statuses, :csys_closed_outcome if index_exists?(:issue_statuses, :csys_closed_outcome)
    remove_column :trackers, :csys_negative_status_ids if column_exists?(:trackers, :csys_negative_status_ids)
    remove_column :issue_statuses, :csys_closed_outcome if column_exists?(:issue_statuses, :csys_closed_outcome)
  end
end
