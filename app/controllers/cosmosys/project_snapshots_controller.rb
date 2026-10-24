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

    before_action :find_project_by_project_id, if: -> { params[:project_id].present? }
    before_action :authorize_project, if: -> { @project.present? }
    before_action :find_snapshot, only: [:show, :download, :destroy, :new_materialization, :materialize]

    helper_method :snapshot_import_form_path, :snapshot_import_cancel_path,
                  :snapshot_import_history_path, :snapshot_import_operation_path, :snapshot_import_status_path

    def index
      @snapshots = Cosmosys::ProjectSnapshot.where(project_id: @project.id, created_by_id: User.current.id).recent_first
      @snapshots = Cosmosys::ProjectSnapshot.where(project_id: @project.id).recent_first if User.current.admin?
      @snapshot_selection = ProjectSnapshotSelection.new(@project, user: User.current)
      @import_operations = User.current.admin? ? ProjectSnapshotImportOperation.recent(user: User.current, project: @project) : []
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
      return deny_access unless User.current.admin?
      @destination = { 'parent_id' => @project&.id, 'identity_mode' => 'preserve' }
      @import_operations = ProjectSnapshotImportOperation.recent(user: User.current, project: @project)
      @parent_projects = Project.visible(User.current).order(:name)
    end

    def import
      return deny_access unless User.current.admin?
      attributes = snapshot_destination_attributes

      if params[:confirmed_plan].present?
        perform_confirmed_import(attributes)
      else
        stage_and_preview_import(attributes)
      end
    rescue ProjectSnapshotPackageError, ProjectCopyError, ActiveRecord::RecordInvalid,
           ActiveRecord::RecordNotFound, ActionController::ParameterMissing, KeyError => error
      flash.now[:error] = error.message
      @destination = params.fetch(:destination, {}).respond_to?(:to_unsafe_h) ? params.fetch(:destination).to_unsafe_h : {}
      @parent_projects = Project.visible(User.current).order(:name)
      render :new_import, status: :unprocessable_entity
    end

    def cancel_import
      return deny_access unless User.current.admin?
      Cosmosys::ProjectSnapshotImportStage.cleanup(params[:import_token].to_s, user: User.current, project: @project)
      redirect_to snapshot_import_history_path, notice: l(:notice_cosmosys_snapshot_import_cancelled)
    end

    def import_operation
      return unless find_import_operation
    end

    def import_status
      return unless find_import_operation

      summary = @import_operation.summary
      response.headers['Cache-Control'] = 'no-store'
      render json: {
        state: @import_operation.state, progress: summary['progress'], phase: summary['progress_phase'],
        phase_label: l("text_cosmosys_snapshot_phase_#{summary['progress_phase']}"),
        processed: summary['processed'], total: summary['total'],
        attachments_processed: summary['attachments_processed'], attachments_total: summary['attachments_total'],
        elapsed_seconds: summary['duration_seconds'] || (Time.now - Time.parse(@import_operation.data.fetch('created_at'))).round(1),
        updated_at: @import_operation.data['updated_at'], duration_seconds: summary['duration_seconds'],
        result_message: summary['result_message'], error: summary['error'],
        destination_url: summary['destination_identifier'].present? ? project_path(summary['destination_identifier']) : nil
      }
    end

    def show; end

    def destroy
      return deny_access unless @snapshot.created_by_id == User.current.id || User.current.admin?
      @snapshot.destroy!
      redirect_to project_cosmosys_snapshots_path(@project), notice: l(:notice_cosmosys_project_snapshot_deleted)
    end

    def new_materialization
      return deny_access unless User.current.admin?
      @destination = destination_defaults
      @parent_projects = Project.visible(User.current).order(:name)
    end

    def materialize
      return deny_access unless User.current.admin?
      attributes = params.require(:destination).permit(:name, :identifier, :cscode, :parent_id, :identity_mode, :project_data_conflict_policy, :is_public)
      plan = Cosmosys::ProjectSnapshotMaterializationPlan.new(
        source: @snapshot, attributes: attributes, user: User.current
      )
      confirmed_digest = Cosmosys::ProjectSnapshotMaterializationPlan.verified_digest(params[:confirmed_plan])
      if params[:review_plan] == '1' || !(confirmed_digest && ActiveSupport::SecurityUtils.secure_compare(confirmed_digest, plan.digest))
        @destination = attributes.to_h
        @parent_projects = Project.visible(User.current).order(:name)
        @materialization_plan = plan
        return render :new_materialization
      end

      raise ProjectCopyError, plan.blocking_messages.join(' ') if plan.blocking_messages.any?

      destination = Cosmosys::ProjectSnapshotMaterializer.new(
        @snapshot, user: User.current,
        attributes: attributes,
        purpose: :snapshot
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

    def snapshot_import_form_path
      @project ? import_project_cosmosys_snapshot_path(@project) : cosmosys_snapshot_import_path
    end

    def snapshot_import_cancel_path(import_token:)
      @project ? cancel_import_project_cosmosys_snapshot_path(@project, import_token: import_token) :
        cancel_cosmosys_snapshot_import_path(import_token: import_token)
    end

    def snapshot_import_history_path
      @project ? project_cosmosys_snapshots_path(@project) : new_cosmosys_snapshot_import_path
    end

    def snapshot_import_operation_path(token)
      @project ? project_cosmosys_snapshot_import_operation_path(@project, token) : cosmosys_snapshot_import_operation_path(token)
    end

    def snapshot_import_status_path(token)
      @project ? status_project_cosmosys_snapshot_import_operation_path(@project, token) : status_cosmosys_snapshot_import_operation_path(token)
    end

    def log_snapshot_import_progress(percent, phase, details = {})
      Rails.logger.info({ cosmosys_snapshot_import: 'progress', project_id: @project&.id,
                          phase: phase, progress: percent, **details }.to_json)
    end

    def find_import_operation
      unless User.current.admin?
        deny_access
        return false
      end

      @import_operation = ProjectSnapshotImportOperation.find(params[:token], user: User.current, project: @project)
      unless @import_operation
        render_404
        return false
      end
      true
    end

    def snapshot_destination_attributes
      params.require(:destination).permit(
        :name, :identifier, :cscode, :parent_id, :identity_mode,
        :project_data_conflict_policy, :primary_source_id, :allow_multiple_roots, :is_public,
        project_identifiers: {}
      )
    end

    # First step of the external .csys import: upload a bounded package, stage
    # it, validate it and build the signed non-writing preflight. Nothing is
    # created; the confirmation screen must be reviewed and re-submitted.
    def stage_and_preview_import(attributes)
      upload = params[:snapshot_file]
      raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_file_required) unless upload.respond_to?(:read) && upload.tempfile

      log_snapshot_import_progress(0, 'staging')
      token = Cosmosys::ProjectSnapshotImportStage.create(upload.tempfile.path, user: User.current, project: @project)
      @destination = attributes.to_h
      @parent_projects = Project.visible(User.current).order(:name)
      path = Cosmosys::ProjectSnapshotImportStage.retrieve(token, user: User.current, project: @project)
      unless path
        Cosmosys::ProjectSnapshotImportStage.cleanup(token, user: User.current, project: @project)
        raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_upload_expired)
      end

      begin
        Cosmosys::ProjectSnapshotPackageReader.open(path, progress: method(:log_snapshot_import_progress)) do |source|
          attributes = complete_import_attributes(attributes, source)
          @destination = attributes
          log_snapshot_import_progress(3, 'preflight')
          @import_plan = Cosmosys::ProjectSnapshotMaterializationPlan.new(
            source: source, attributes: attributes, user: User.current
          )
        end
      rescue StandardError
        # An invalid or unplanable package must not keep a staged upload: the
        # user must fix the package before a further confirmation step.
        Cosmosys::ProjectSnapshotImportStage.cleanup(token, user: User.current, project: @project)
        raise
      end
      @import_token = token
      render :new_import
    end

    # Second step: only after the preflight digest still matches the current
    # plan does the import materialize, using the exact staged bytes reviewed.
    # The staged upload is removed after a completed or failed materialization;
    # a changed preflight keeps the stage so the user can confirm the new plan.
    def perform_confirmed_import(attributes)
      token = params[:import_token].to_s
      confirmed_digest = Cosmosys::ProjectSnapshotMaterializationPlan.verified_digest(params[:confirmed_plan])
      path = Cosmosys::ProjectSnapshotImportStage.retrieve(token, user: User.current, project: @project)
      unless confirmed_digest && path
        Cosmosys::ProjectSnapshotImportStage.cleanup(token, user: User.current, project: @project)
        @destination = attributes.to_h
        @parent_projects = Project.visible(User.current).order(:name)
        return render :new_import
      end

      Cosmosys::ProjectSnapshotPackageReader.open(path, progress: method(:log_snapshot_import_progress)) do |source|
        attributes = complete_import_attributes(attributes, source)
        plan = Cosmosys::ProjectSnapshotMaterializationPlan.new(
          source: source, attributes: attributes, user: User.current
        )
        if params[:review_plan] == '1' || !ActiveSupport::SecurityUtils.secure_compare(confirmed_digest, plan.digest)
          @import_plan = plan
          @import_token = token
          @destination = attributes.to_h
          @parent_projects = Project.visible(User.current).order(:name)
          return render :new_import
        end
        raise ProjectCopyError, plan.blocking_messages.join(' ') if plan.blocking_messages.any?

        if params[:background] == '1'
          operation = ProjectSnapshotImportOperation.create(
            path, user: User.current, project: @project, attributes: attributes,
            confirmed_plan: params[:confirmed_plan].to_s
          )
          begin
            ProjectSnapshotImportJob.perform_later(operation.token)
          rescue StandardError => error
            operation.update!(state: 'failed', summary: operation.summary.merge('progress_phase' => 'failed', 'error' => error.message))
            operation.release_package!
            raise
          end
          ProjectSnapshotImportStage.cleanup(token, user: User.current, project: @project)
          ProjectSnapshotImportOperation.cleanup_expired!
          return redirect_to snapshot_import_operation_path(operation.token)
        end

        begin
          destination = Cosmosys::ProjectSnapshotMaterializer.new(
            source, user: User.current, attributes: attributes, purpose: :snapshot
          ).call
        ensure
          Cosmosys::ProjectSnapshotImportStage.cleanup(token, user: User.current, project: @project)
        end
        notice = Cosmosys::ProjectSnapshotMaterializationSummary.new(project: destination, plan: plan).message
        redirect_to project_path(destination), notice: notice
      end
    end

    def complete_import_attributes(attributes, source)
      values = attributes.to_h.deep_stringify_keys
      content = source.manifest.fetch('content')
      values['primary_source_id'] = content['primary_project_source_id'].to_s if values['primary_source_id'].blank?
      values['allow_multiple_roots'] = '1'
      overrides = (values['project_identifiers'] || {}).stringify_keys
      content.fetch('projects').each do |entry|
        source_id = entry.fetch('source_id').to_s
        next if source_id == values['primary_source_id']

        overrides[source_id] ||= entry.fetch('project').fetch('identifier')
      end
      values['project_identifiers'] = overrides
      values
    end

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
