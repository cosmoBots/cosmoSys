require 'tempfile'

module Cosmosys
  class ProjectSnapshotsController < ApplicationController
    menu_item :cosmosys

    before_action :find_project_by_project_id
    before_action :authorize_project
    before_action :find_snapshot, only: [:show, :download, :destroy, :new_materialization, :materialize]

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

    def destroy
      deny_access unless @snapshot.created_by_id == User.current.id || User.current.admin?
      @snapshot.destroy!
      redirect_to project_cosmosys_snapshots_path(@project), notice: l(:notice_cosmosys_project_snapshot_deleted)
    end

    def new_materialization
      deny_access unless User.current.admin?
      @destination = destination_defaults
      @parent_projects = Project.visible(User.current).order(:name)
    end

    def materialize
      deny_access unless User.current.admin?
      destination = Cosmosys::ProjectSnapshotMaterializer.new(
        @snapshot, user: User.current, attributes: params.require(:destination).permit(:name, :identifier, :cscode, :parent_id)
      ).call
      redirect_to project_path(destination), notice: l(:notice_cosmosys_project_snapshot_materialized)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, KeyError => error
      flash.now[:error] = error.message
      @destination = params.fetch(:destination, {}).to_unsafe_h
      @parent_projects = Project.visible(User.current).order(:name)
      render :new_materialization, status: :unprocessable_entity
    end

    def download
      temporary = Tempfile.new(["cosmosys-snapshot-#{@snapshot.id}", '.csys'])
      temporary.close
      Cosmosys::ProjectSnapshotPackage.new(@snapshot).write(temporary.path)
      send_file(
        temporary.path,
        filename: "#{@project.identifier}-snapshot-#{@snapshot.id}.csys",
        type: 'application/zip',
        disposition: 'attachment'
      )
      self.response_body = Rack::BodyProxy.new(response_body) { temporary.unlink }
    rescue StandardError
      temporary&.unlink
      raise
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

    def destination_defaults
      source = @snapshot.manifest.fetch('content').fetch('project')
      { 'name' => "#{source.fetch('name')} snapshot #{@snapshot.id}",
        'identifier' => "#{source.fetch('identifier')}-snapshot-#{@snapshot.id}",
        'cscode' => source.fetch('cscode'), 'parent_id' => nil }
    end
  end
end
