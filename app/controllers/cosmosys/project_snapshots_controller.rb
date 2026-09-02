module Cosmosys
  class ProjectSnapshotsController < ApplicationController
    menu_item :cosmosys

    before_action :find_project_by_project_id
    before_action :authorize_project
    before_action :find_snapshot, only: [:show, :download]

    def index
      @snapshots = Cosmosys::ProjectSnapshot.where(project_id: @project.id, created_by_id: User.current.id).recent_first
      @snapshots = Cosmosys::ProjectSnapshot.where(project_id: @project.id).recent_first if User.current.admin?
    end

    def create
      snapshot = Cosmosys::ProjectSnapshotCapture.new(
        @project,
        user: User.current,
        name: params[:name]
      ).call
      redirect_to project_cosmosys_snapshot_path(@project, snapshot), notice: l(:notice_cosmosys_project_snapshot_created)
    rescue ActiveRecord::RecordInvalid => error
      redirect_to project_cosmosys_snapshots_path(@project), alert: error.record.errors.full_messages.join(', ')
    end

    def show; end

    def download
      send_data(
        @snapshot.manifest_json,
        filename: "#{@project.identifier}-snapshot-#{@snapshot.id}.json",
        type: 'application/json',
        disposition: 'attachment'
      )
    end

    private

    def authorize_project
      deny_access unless @project.visible?(User.current)
    end

    def find_snapshot
      @snapshot = Cosmosys::ProjectSnapshot.find_by(id: params[:id], project_id: @project.id)
      return render_404 unless @snapshot
      deny_access unless @snapshot.readable_by?(User.current)
    end
  end
end
