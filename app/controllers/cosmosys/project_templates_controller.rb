module Cosmosys
  class ProjectTemplatesController < ApplicationController
    menu_item :settings

    before_action :find_project_by_project_id
    before_action :authorize_project_settings

    def profile
      profile = @project.cosmosys_project_profile_definition
      send_ods_template(
        Rails.root.join(profile.ods_export_template),
        "#{profile.key}-base-template.ods"
      )
    end

    def effective
      resolution = @project.cosmosys_effective_ods_template
      filename = resolution.asset&.original_filename.presence || "#{resolution.profile.key}-base-template.ods"
      send_ods_template(resolution.path, filename)
    end

    def report_profile
      profile = @project.cosmosys_project_profile_definition
      send_report_template(Rails.root.join(profile.report_export_template), "#{profile.key}-report-template.odt")
    end

    def report_effective
      resolution = @project.cosmosys_effective_report_template
      filename = resolution.asset&.original_filename.presence || "#{resolution.profile.key}-report-template.odt"
      send_report_template(resolution.path, filename)
    end

    private

    def authorize_project_settings
      deny_access unless User.current.allowed_to?(:edit_project, @project)
    end

    def send_ods_template(path, filename)
      path = Pathname.new(path.to_s)
      raise ActiveRecord::RecordNotFound unless path.file?

      send_file(
        path,
        filename: filename,
        type: Cosmosys::OdsExportService::CONTENT_TYPE,
        disposition: 'attachment'
      )
    end


    def send_report_template(path, filename)
      path = Pathname.new(path.to_s)
      raise ActiveRecord::RecordNotFound unless path.file?
      send_file(path, filename: filename, type: Cosmosys::ReportExportService::FORMATS.fetch('odt'), disposition: 'attachment')
    end
  end
end
