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
      status = status_class.where(status_class.arel_table[:name].lower.eq(name.downcase)).first || status_class.new(name: name)
      status.is_closed = true
      status.position ||= status_class.maximum(:position).to_i + 1
      status.csys_closed_outcome = outcome
      status.save!
    end

    GENERIC_MATURITY.each do |name, maturity|
      status_class.where(status_class.arel_table[:name].lower.eq(name.downcase)).update_all(csys_maturity: maturity)
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
    status_id = status_class.order(:position, :id).pick(:id)
    return if status_id.blank?

    tracker = tracker_class.find_by(csys_key: 'cs_negative') || tracker_class.new
    tracker.assign_attributes(
      name: 'csNegative',
      csys_key: 'cs_negative',
      csys_item_kind: 'negative',
      default_status_id: status_id
    )
    tracker.save!
    project_class = Class.new(ActiveRecord::Base) { self.table_name = 'projects' }
    assignment_class = Class.new(ActiveRecord::Base) do
      self.table_name = 'projects_trackers'
      self.primary_key = nil
    end
    project_class.find_each do |project|
      assignment_class.find_or_create_by!(project_id: project.id, tracker_id: tracker.id)
    end
  end

  def down
    tracker_class = Class.new(ActiveRecord::Base) { self.table_name = 'trackers' }
    assignment_class = Class.new(ActiveRecord::Base) { self.table_name = 'projects_trackers' }
    tracker_id = tracker_class.find_by(csys_key: 'cs_negative')&.id
    if tracker_id.present?
      assignment_class.where(tracker_id: tracker_id).delete_all
      tracker_class.where(id: tracker_id).delete_all
    end
    remove_index :issue_statuses, :csys_closed_outcome if index_exists?(:issue_statuses, :csys_closed_outcome)
    remove_column :issues, :csys_negative_status_id if column_exists?(:issues, :csys_negative_status_id)
    remove_column :issue_statuses, :csys_maturity if column_exists?(:issue_statuses, :csys_maturity)
    remove_column :issue_statuses, :csys_closed_outcome if column_exists?(:issue_statuses, :csys_closed_outcome)
  end
end
