module Cosmosys
  module IssuesControllerPatch
    private

    def build_new_issue_from_params
      result = super
      return result unless result
      return result unless action_name == 'new' && request.get?
      return result if params.dig(:issue, :tracker_id).present? || params.dig(:issue, :parent_issue_id).present?

      preferred = @issue.project&.cosmosys_root_tracker
      @issue.tracker = preferred if preferred && @issue.allowed_target_trackers.include?(preferred)
      @issue.status = @issue.tracker.default_status if preferred && @issue.tracker == preferred
      result
    end
  end
end
