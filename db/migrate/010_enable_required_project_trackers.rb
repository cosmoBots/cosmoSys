class EnableRequiredProjectTrackers < ActiveRecord::Migration[6.1]
  def up
    # Use table records rather than Project saves: legacy projects may not yet
    # satisfy current validations. The registry includes installed extensions.
    project_class = Class.new(ActiveRecord::Base) { self.table_name = 'projects' }
    tracker_class = Class.new(ActiveRecord::Base) { self.table_name = 'trackers' }
    assignment_class = Class.new(ActiveRecord::Base) do
      self.table_name = 'projects_trackers'
      self.primary_key = nil
    end
    project_class.reset_column_information
    project_class.distinct.pluck(:csys_project_profile).each do |profile_key|
      profile = Cosmosys::ProjectProfileRegistry.fetch(profile_key)
      keys = profile.required_trackers.map { |entry| entry.fetch(:key) }
      tracker_ids = tracker_class.where(csys_key: keys).pluck(:id)
      project_class.where(csys_project_profile: profile_key).find_each do |project|
        tracker_ids.each do |tracker_id|
          assignment_class.find_or_create_by!(project_id: project.id, tracker_id: tracker_id)
        end
      end
    end
  end

  def down
    # Keep assignments: existing and backfilled links cannot be distinguished,
    # and items may now depend on the enabled trackers.
  end
end
