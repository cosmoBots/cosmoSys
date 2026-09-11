require_dependency 'issue'

module Cosmosys
  module IssueWorkflowPatch
    def new_statuses_allowed_to(user = User.current, include_default = false)
      statuses = super
      return statuses unless blocked?
      return statuses unless cosmosys_item_kind.allow_unsuccessful_closure_when_blocked

      unsuccessful = cosmosys_workflow_statuses_allowed_to(user).select do |candidate|
        candidate.respond_to?(:cosmosys_unsuccessfully_closed?) && candidate.cosmosys_unsuccessfully_closed?
      end
      (statuses + unsuccessful).compact.uniq.sort
    end

    private

    # Mirrors Redmine's workflow lookup before Issue#new_statuses_allowed_to
    # removes every closed state from a blocked item. It deliberately restores
    # only transitions already granted by the workflow and roles.
    def cosmosys_workflow_statuses_allowed_to(user)
      initial_status =
        if new_record?
          nil
        elsif tracker_id_changed?
          if Tracker.where(id: tracker_id_was, default_status_id: status_id_was).any?
            default_status
          elsif tracker.issue_status_ids.include?(status_id_was)
            IssueStatus.find_by(id: status_id_was)
          else
            default_status
          end
        else
          status_was
        end

      initial_assigned_to_id = assigned_to_id_changed? ? assigned_to_id_was : assigned_to_id
      assignee_transition = initial_assigned_to_id.present? &&
        (user.id == initial_assigned_to_id || user.group_ids.include?(initial_assigned_to_id))

      IssueStatus.new_statuses_allowed(
        initial_status,
        roles_for_workflow(user),
        tracker,
        author == user,
        assignee_transition
      )
    end
  end
end
