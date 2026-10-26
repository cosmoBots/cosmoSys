module Cosmosys
  # Read-only forest audit. parent_id is the source of hierarchy truth.
  class ProjectTreeAudit
    def call
      rows = Project.order(:lft, :id).pluck(:id, :parent_id, :lft, :rgt, :status, :updated_on)
      problems = []
      boundaries = {}
      stack = []
      rows.each do |id, parent, left, right, status, updated|
        unless left && right && left < right
          problems << { project_id: id, reason: 'invalid_interval' }
          next
        end
        [left, right].each do |boundary|
          problems << { project_id: id, reason: 'duplicate_boundary' } if boundaries.key?(boundary)
          boundaries[boundary] = id
        end
        stack.pop while stack.any? && stack.last[2] < left
        if stack.last&.first != parent || (stack.any? && right >= stack.last[2])
          problems << { project_id: id, reason: 'parent_interval_mismatch' }
        end
        stack << [id, left, right]
      end
      pending = rows.filter_map do |id, _parent, _left, _right, status, updated|
        id if status == Project::STATUS_SCHEDULED_FOR_DELETION && updated && updated < 1.hour.ago
      end
      { healthy: problems.empty?, checked_projects: rows.size, problems: problems,
        scheduled_deletion_project_ids: rows.select { |row| row[4] == Project::STATUS_SCHEDULED_FOR_DELETION }.map(&:first),
        stale_scheduled_deletion_project_ids: pending }
    end
  end
end
