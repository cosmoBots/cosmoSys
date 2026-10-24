require 'uri'

module Cosmosys
  module IssuesControllerPatch
    def redirect_after_create
      editor_return = cosmosys_tree_editor_return
      return super unless editor_return

      if editor_return[:mode] == 'sibling' && User.current.allowed_to?(:edit_issues, @issue.project)
        reference = Issue.find_by(
          id: editor_return[:reference_id],
          project_id: @issue.project_id,
          parent_id: @issue.parent_id
        )
        if reference
          Issue.transaction do
            Cosmosys::SiblingOrder.move_after(@issue, reference)
            @issue.save! if @issue.errors.empty?
          end
        end
      end

      redirect_to url_for(
        controller: '/cosmosys/items', action: :tree,
        project_id: @issue.project, focus_issue_id: @issue.id
      )
    end

    private

    def cosmosys_tree_editor_return
      raw_url = params[:back_url].to_s
      return if raw_url.blank?

      uri = URI.parse(raw_url)
      expected_path = url_for(controller: '/cosmosys/items', action: :tree, project_id: @issue.project, only_path: true)
      return unless uri.path == expected_path

      values = Rack::Utils.parse_nested_query(uri.query)
      mode = values['cosmosys_editor_mode'].to_s
      return { mode: mode } if mode == 'root'
      return unless %w[child sibling].include?(mode)

      reference_id = values['cosmosys_editor_reference_id'].to_s
      return if reference_id.blank? || !reference_id.match?(/\A\d+\z/)

      { mode: mode, reference_id: reference_id }
    rescue URI::InvalidURIError
      nil
    end

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
