class AddCosmosysIssueStatusOutcome < ActiveRecord::Migration[6.1]
  GENERIC_CLOSURE_STATUSES = {
    'Closed' => 'successful',
    'Rejected' => 'unsuccessful'
  }.freeze
  GENERIC_MATURITY = {
    'Rejected' => 0,
    'New' => 1,
    'In Progress' => 2,
    'Feedback' => 2,
    'Resolved' => 3,
    'Closed' => 4
  }.freeze

  def up
    add_column :issue_statuses, :csys_closed_outcome, :string unless column_exists?(:issue_statuses, :csys_closed_outcome)
    add_index :issue_statuses, :csys_closed_outcome unless index_exists?(:issue_statuses, :csys_closed_outcome)
    add_column :issue_statuses, :csys_maturity, :integer unless column_exists?(:issue_statuses, :csys_maturity)
    add_column :issues, :csys_negative_status_id, :integer unless column_exists?(:issues, :csys_negative_status_id)

    GENERIC_CLOSURE_STATUSES.each do |name, outcome|
      status = status_class.where('LOWER(name) = ?', name.downcase).first || status_class.new(name: name)
      status.is_closed = true
      status.position ||= status_class.maximum(:position).to_i + 1
      status.csys_closed_outcome = outcome
      status.save!
    end

    GENERIC_MATURITY.each do |name, maturity|
      status_class.where('LOWER(name) = ?', name.downcase).update_all(csys_maturity: maturity)
    end

    install_negative_tracker
  end

  private

  def status_class
    @status_class ||= Class.new(ActiveRecord::Base) { self.table_name = 'issue_statuses' }.tap(&:reset_column_information)
  end

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
    remove_column :issues, :csys_negative_status_id if column_exists?(:issues, :csys_negative_status_id)
    remove_column :issue_statuses, :csys_maturity if column_exists?(:issue_statuses, :csys_maturity)
    remove_column :issue_statuses, :csys_closed_outcome if column_exists?(:issue_statuses, :csys_closed_outcome)
  end
end
