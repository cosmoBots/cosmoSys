class EnableRequiredProjectTrackers < ActiveRecord::Migration[6.1]
  def up
    # Use table records rather than Project saves: legacy projects may not yet
    # satisfy current validations. The registry includes installed extensions.
    project_class = Class.new(ActiveRecord::Base) { self.table_name = 'projects' }
    project_class.reset_column_information
    project_class.distinct.pluck(:csys_project_profile).each do |profile_key|
      profile = Cosmosys::ProjectProfileRegistry.fetch(profile_key)
      keys = profile.required_trackers.map { |entry| connection.quote(entry.fetch(:key)) }
      project_ids = project_class.where(csys_project_profile: profile_key).select(:id).to_sql
      execute <<~SQL
        INSERT INTO projects_trackers (project_id, tracker_id)
        SELECT projects.id, trackers.id
        FROM projects CROSS JOIN trackers
        WHERE projects.id IN (#{project_ids})
          AND trackers.csys_key IN (#{keys.join(', ')})
          AND NOT EXISTS (
            SELECT 1 FROM projects_trackers
            WHERE projects_trackers.project_id = projects.id
              AND projects_trackers.tracker_id = trackers.id
          )
      SQL
    end
  end

  def down
    # Keep assignments: existing and backfilled links cannot be distinguished,
    # and items may now depend on the enabled trackers.
  end
end
