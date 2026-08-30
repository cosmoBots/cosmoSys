require 'digest'
require 'securerandom'

module Cosmosys
  class OdsTransfersController < ApplicationController
    menu_item :cosmosys

    before_action :find_project_by_project_id
    before_action :authorize_read, only: [:index, :show, :status, :download]
    before_action :authorize_edit, only: [:new, :create, :apply]
    before_action :authorize_admin, only: [:new_materialization, :create_materialization, :materialize]
    before_action :find_transfer, only: [:show, :status, :apply, :download, :materialize]

    def index
      @transfers = Cosmosys::OdsTransfer.where(project_id: @project.id).includes(:project, :user).recent_first.limit(100)
    end

    def new
    end

    def new_materialization
      @destination = { 'name' => "#{@project.name} snapshot", 'identifier' => "#{@project.identifier}-snapshot", 'cscode' => "#{@project.cscode}S" }
    end

    def create_materialization
      upload = params[:ods_file]
      @destination = params.fetch(:destination, {}).permit(:name, :identifier, :cscode, :description, :archive).to_h
      return render(:new_materialization, status: :unprocessable_entity) unless upload.respond_to?(:read)
      data = upload.read
      if data.blank? || data.bytesize > 50.megabytes
        flash.now[:error] = l(:error_cosmosys_ods_invalid_size)
        return render(:new_materialization, status: :unprocessable_entity)
      end
      transfer = Cosmosys::OdsTransfer.create!(project: @project, user: User.current, direction: 'materialize', state: 'uploaded',
        original_filename: upload.original_filename.to_s, content_type: upload.content_type.to_s, byte_size: data.bytesize,
        file_sha256: Digest::SHA256.hexdigest(data), export_id: SecureRandom.uuid,
        format_version: Cosmosys::OdsExportService::FORMAT_VERSION, file_data: data)
      Cosmosys::OdsProjectMaterializer.new(transfer, user: User.current, destination_attributes: @destination,
        mode: params[:copy_mode], profile_key: params[:project_profile]).analyse!
      redirect_to project_cosmosys_ods_transfer_path(@project, transfer)
    end

    def create
      upload = params[:ods_file]
      return render(:new, status: :unprocessable_entity) unless upload.respond_to?(:read)

      data = upload.read
      if data.blank? || data.bytesize > 50.megabytes
        flash.now[:error] = l(:error_cosmosys_ods_invalid_size)
        return render(:new, status: :unprocessable_entity)
      end

      transfer = Cosmosys::OdsTransfer.create!(
        project: @project,
        user: User.current,
        direction: 'import',
        state: 'uploaded',
        original_filename: upload.original_filename.to_s,
        content_type: upload.content_type.to_s,
        byte_size: data.bytesize,
        file_sha256: Digest::SHA256.hexdigest(data),
        export_id: SecureRandom.uuid,
        format_version: Cosmosys::OdsExportService::FORMAT_VERSION,
        file_data: data
      )
      Cosmosys::OdsImportService.new(transfer, user: User.current).analyse!
      redirect_to project_cosmosys_ods_transfer_path(@project, transfer)
    end

    def show
      @events = @transfer.events.order(:id)
    end

    def status
      summary = @transfer.summary
      phase = summary['progress_phase'].presence || @transfer.state
      render json: {
        id: @transfer.id,
        state: @transfer.state,
        progress: summary['progress'].to_i.clamp(0, 100),
        phase: phase,
        phase_label: I18n.t("text_cosmosys_ods_export_phase_#{phase}", default: phase.to_s.humanize),
        writer: summary['writer'],
        duration_seconds: summary['duration_seconds'],
        completion_label: summary['duration_seconds'].present? ? I18n.t(:text_cosmosys_ods_export_completed_in, duration: format('%.1f', summary['duration_seconds'])) : nil,
        download_url: @transfer.applied? ? download_project_cosmosys_ods_transfer_path(@project, @transfer) : nil,
        filename: @transfer.original_filename
      }
    end

    def apply
      Cosmosys::OdsImportService.new(@transfer, user: User.current).apply!
      if @transfer.reload.applied?
        flash[:notice] = l(:notice_cosmosys_ods_import_applied)
      else
        flash[:error] = l(:error_cosmosys_ods_import_failed)
      end
      redirect_to project_cosmosys_ods_transfer_path(@project, @transfer)
    end

    def materialize
      Cosmosys::OdsProjectMaterializer.new(@transfer, user: User.current).apply!
      if @transfer.reload.applied?
        redirect_to project_path(Project.find(@transfer.summary['destination_project_id'])), notice: l(:notice_cosmosys_snapshot_materialized)
      else
        redirect_to project_cosmosys_ods_transfer_path(@project, @transfer), alert: l(:error_cosmosys_snapshot_materialization_failed)
      end
    end

    def download
      payload = @transfer.export_payload
      return render_404 if payload.blank?

      send_data(
        payload,
        filename: @transfer.direction == 'export' ? @transfer.original_filename : "#{File.basename(@transfer.original_filename.to_s, '.ods')}-reconciled.ods",
        type: Cosmosys::OdsExportService::CONTENT_TYPE,
        disposition: 'attachment'
      )
    end

    private

    def find_transfer
      @transfer = Cosmosys::OdsTransfer.find_by(id: params[:id], project_id: @project.id)
      render_404 unless @transfer
    end

    def authorize_read
      render_403 unless @project.visible?(User.current)
    end

    def authorize_edit
      render_403 unless User.current.allowed_to?(:edit_project, @project)
    end

    def authorize_admin
      render_403 unless User.current.admin?
    end
  end
end
