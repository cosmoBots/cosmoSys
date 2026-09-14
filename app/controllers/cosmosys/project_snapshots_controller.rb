require 'tempfile'

module Cosmosys
  class ProjectSnapshotsController < ApplicationController
    class DownloadBody
      def initialize(body, temporary)
        @body = body
        @temporary = temporary
      end

      def each(&block)
        @body.each(&block)
      ensure
        cleanup
      end

      def close
        @body.close if @body.respond_to?(:close)
      ensure
        cleanup
      end

      private

      def cleanup
        @temporary.unlink
      rescue Errno::ENOENT
        nil
      end
    end

    menu_item :cosmosys

    before_action :find_project_by_project_id
    before_action :authorize_project
    before_action :find_snapshot, only: [:show, :download, :destroy, :new_materialization, :materialize]

    def index
      @snapshots = Cosmosys::ProjectSnapshot.where(project_id: @project.id, created_by_id: User.current.id).recent_first
      @snapshots = Cosmosys::ProjectSnapshot.where(project_id: @project.id).recent_first if User.current.admin?
      @snapshot_selection = ProjectSnapshotSelection.new(@project, user: User.current)
    end

    def create
      snapshot = Cosmosys::ProjectSnapshotCapture.new(
        @project,
        user: User.current,
        name: params[:name],
        projects: params[:project_ids] || []
      ).call
      redirect_to project_cosmosys_snapshot_path(@project, snapshot), notice: l(:notice_cosmosys_project_snapshot_created)
    rescue ActiveRecord::RecordInvalid, ArgumentError => error
      message = error.respond_to?(:record) ? error.record.errors.full_messages.join(', ') : error.message
      redirect_to project_cosmosys_snapshots_path(@project), alert: message
    end

    def new_import
      deny_access unless User.current.admin?
      @destination = { 'parent_id' => @project.id, 'identity_mode' => 'preserve' }
      @parent_projects = Project.visible(User.current).order(:name)
    end

    def import
      deny_access unless User.current.admin?
      upload = params.require(:snapshot_file)
      destination = nil
      Cosmosys::ProjectSnapshotPackageReader.open(upload.tempfile.path) do |source|
        destination = Cosmosys::ProjectSnapshotMaterializer.new(
          source, user: User.current,
          attributes: params.require(:destination).permit(:name, :identifier, :cscode, :parent_id, :identity_mode, :project_data_conflict_policy)
        ).call
      end
      redirect_to project_path(destination), notice: l(:notice_cosmosys_project_snapshot_materialized)
    rescue ProjectSnapshotPackageError, ProjectCopyError, ActiveRecord::RecordInvalid,
           ActiveRecord::RecordNotFound, ActionController::ParameterMissing, KeyError => error
      flash.now[:error] = error.message
      @destination = params.fetch(:destination, {}).respond_to?(:to_unsafe_h) ? params.fetch(:destination).to_unsafe_h : {}
      @parent_projects = Project.visible(User.current).order(:name)
      render :new_import, status: :unprocessable_entity
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
      attributes = params.require(:destination).permit(:name, :identifier, :cscode, :parent_id, :identity_mode, :project_data_conflict_policy)
      plan = Cosmosys::ProjectSnapshotMaterializationPlan.new(source: @snapshot, attributes: attributes)
      confirmed_digest = Cosmosys::ProjectSnapshotMaterializationPlan.verified_digest(params[:confirmed_plan])
      unless confirmed_digest && ActiveSupport::SecurityUtils.secure_compare(confirmed_digest, plan.digest)
        @destination = attributes.to_h
        @parent_projects = Project.visible(User.current).order(:name)
        @materialization_plan = plan
        return render :new_materialization
      end

      raise ProjectCopyError, plan.blocking_messages.join(' ') if plan.blocking_messages.any?

      destination = Cosmosys::ProjectSnapshotMaterializer.new(
        @snapshot, user: User.current,
        attributes: attributes
      ).call
      notice = Cosmosys::ProjectSnapshotMaterializationSummary.new(project: destination, plan: plan).message
      redirect_to project_path(destination), notice: notice
    rescue ProjectSnapshotPackageError, ProjectCopyError, ActiveRecord::RecordInvalid,
           ActiveRecord::RecordNotFound, ActionController::ParameterMissing, KeyError => error
      flash.now[:error] = error.message
      raw_destination = params.fetch(:destination, {})
      @destination = raw_destination.respond_to?(:to_unsafe_h) ? raw_destination.to_unsafe_h : {}
      @parent_projects = Project.visible(User.current).order(:name)
      render :new_materialization, status: :unprocessable_entity
    end

    def download
      temporary = Tempfile.new(["cosmosys-snapshot-#{@snapshot.id}", '.csys'])
      temporary.close
      Cosmosys::ProjectSnapshotPackage.new(@snapshot).write(temporary.path)
      download_file = File.open(temporary.path, 'rb')
      send_file_headers!(
        filename: "#{@project.identifier}-snapshot-#{@snapshot.id}.csys",
        type: 'application/zip',
        disposition: 'attachment'
      )
      response.headers['Content-Length'] = download_file.size.to_s
      self.response_body = DownloadBody.new(download_file, temporary)
    rescue StandardError
      download_file&.close
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
      source = @snapshot.manifest.fetch('content').fetch('projects').fetch(0).fetch('project')
      { 'name' => "#{source.fetch('name')} snapshot #{@snapshot.id}",
        'identifier' => "#{source.fetch('identifier')}-snapshot-#{@snapshot.id}",
        'cscode' => source.fetch('cscode'), 'parent_id' => nil,
        'identity_mode' => 'preserve', 'profile' => source.fetch('profile') }
    end
  end
end
