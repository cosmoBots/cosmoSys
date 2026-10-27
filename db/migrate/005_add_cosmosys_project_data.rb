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
    create_presentation_baselines_table unless table_exists?(:cosmosys_presentation_baselines)
    migrate_legacy_negative_status_selections

    install_trackers
  end

  def down
    TRACKERS.each_key do |key|
      tracker_id = tracker_record.find_by(csys_key: key)&.id
      next if tracker_id.blank?
      next if issue_record.where(tracker_id: tracker_id).exists?

      assignment_record.where(tracker_id: tracker_id).delete_all
      workflow_record.where(tracker_id: tracker_id).delete_all if table_exists?(:workflows)
      tracker_record.where(id: tracker_id).delete_all
    end

    remove_negative_status_selections_table if table_exists?(:cosmosys_negative_statuses)
    drop_table :cosmosys_presentation_baselines if table_exists?(:cosmosys_presentation_baselines)

    remove_index :issues, :csys_datum_source_issue_id if index_exists?(:issues, :csys_datum_source_issue_id)
    remove_column :issues, :csys_datum_source_issue_id if column_exists?(:issues, :csys_datum_source_issue_id)
    remove_column :issues, :csys_value if column_exists?(:issues, :csys_value)
  end

  private

  def tracker_record
    @tracker_record ||= Class.new(ActiveRecord::Base) { self.table_name = 'trackers' }
  end

  def issue_record
    @issue_record ||= Class.new(ActiveRecord::Base) { self.table_name = 'issues' }
  end

  def assignment_record
    @assignment_record ||= Class.new(ActiveRecord::Base) do
      self.table_name = 'projects_trackers'
      self.primary_key = nil
    end
  end

  def workflow_record
    @workflow_record ||= Class.new(ActiveRecord::Base) do
      self.table_name = 'workflows'
      self.inheritance_column = :_disabled_type
    end
  end

  def create_presentation_baselines_table
    create_table :cosmosys_presentation_baselines do |t|
      t.references :issue, null: false, foreign_key: { to_table: :issues }
      t.string :attribute_name, null: false
      t.text :source_text, null: false
      t.text :resolved_text, null: false
      t.text :ledger_json, null: false
      t.string :resolved_sha256, null: false
      t.integer :captured_status_id
      t.integer :captured_maturity, null: false
      t.datetime :captured_at, null: false
      t.timestamps null: false
    end
    add_index :cosmosys_presentation_baselines, [:issue_id, :attribute_name],
              unique: true, name: 'index_csys_presentation_baselines_on_issue_and_attribute'
  end

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

    selection_record = Class.new(ActiveRecord::Base) { self.table_name = 'cosmosys_negative_statuses' }
    issue_record.where.not(csys_negative_status_id: nil).find_each do |issue|
      selection_record.find_or_create_by!(issue_id: issue.id, issue_status_id: issue.csys_negative_status_id)
      issue.update_columns(csys_negative_status_id: nil)
    end
  end

  def install_trackers
    tracker_class = Class.new(ActiveRecord::Base) { self.table_name = 'trackers' }
    tracker_class.reset_column_information
    status_record = Class.new(ActiveRecord::Base) { self.table_name = 'issue_statuses' }
    status_id = status_record.order(:position, :id).pick(:id)
    raise 'cosmoSys project data requires at least one Redmine item status' if status_id.blank?

    TRACKERS.each do |key, definition|
      tracker = tracker_class.find_by(csys_key: key) ||
                tracker_class.where(tracker_class.arel_table[:name].lower.eq(definition.fetch(:name).downcase)).order(:id).first ||
                tracker_class.new
      tracker.assign_attributes(
        name: definition.fetch(:name),
        csys_key: key,
        csys_item_kind: definition.fetch(:item_profile),
        default_status_id: status_id
      )
      tracker.save!
      copy_feature_workflow(tracker.id)
      project_record = Class.new(ActiveRecord::Base) { self.table_name = 'projects' }
      project_record.find_each do |project|
        assignment_record.find_or_create_by!(project_id: project.id, tracker_id: tracker.id)
      end
    end
  end

  def copy_feature_workflow(tracker_id)
    return unless table_exists?(:workflows)

    feature_id = tracker_record.where(tracker_record.arel_table[:name].lower.eq('feature')).order(:id).pick(:id)
    return if feature_id.blank? || feature_id.to_i == tracker_id.to_i

    workflow_record.where(tracker_id: tracker_id).delete_all
    workflow_record.where(tracker_id: feature_id).find_each do |workflow|
      workflow_record.create!(workflow.attributes.except('id').merge('tracker_id' => tracker_id))
    end
  end
end
