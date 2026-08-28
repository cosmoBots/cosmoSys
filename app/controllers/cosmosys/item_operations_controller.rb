module Cosmosys
  class ItemOperationsController < ApplicationController
    before_action :find_issue
    before_action :require_editable

    def split
      return render :split unless request.post?

      result = Cosmosys::TaskSplitter.new(issue: @issue, count: params[:count], user: User.current).call
      flash[:notice] = l(:notice_cosmosys_task_split, count: result.children.length)
      redirect_to issue_path(@issue)
    rescue ArgumentError, ActiveRecord::RecordInvalid => error
      flash.now[:error] = error.message
      render :split, status: :unprocessable_entity
    end

    def related
      @trackers = @project.trackers.sorted
      return render :related unless request.post?

      tracker = @project.trackers.find(params[:tracker_id])
      result = Cosmosys::RelatedItemsCreator.new(
        source: @issue,
        count: params[:count],
        operation: params[:operation],
        tracker: tracker,
        restricted: params[:restricted],
        user: User.current
      ).call
      flash[:notice] = l(:notice_cosmosys_related_items_created, count: result.issues.length)
      redirect_to issue_path(@issue)
    rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => error
      @trackers ||= @project.trackers.sorted
      flash.now[:error] = error.message
      render :related, status: :unprocessable_entity
    end

    private

    def find_issue
      @issue = Issue.find(params[:issue_id])
      @project = @issue.project
      raise Unauthorized unless @issue.visible?(User.current)
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    def require_editable
      raise Unauthorized unless @issue.editable?(User.current)
      permission = action_name == 'split' ? :manage_subtasks : :manage_issue_relations
      raise Unauthorized unless User.current.allowed_to?(permission, @project)
      raise Unauthorized unless User.current.allowed_to?(:add_issues, @project)
    end
  end
end
