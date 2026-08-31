module Cosmosys
  class ProjectSettingsController < ApplicationController
    menu_item :settings

    before_action :find_project_by_project_id
    before_action :authorize_project_settings

    def update
      update_project_profile!
      query = Cosmosys::MainReportFieldRegistry.query_for_project(@project, user: User.current)
      available_names = query.available_inline_columns.map { |column| column.name.to_s }
      selected_names = Array(params.dig(:cosmosys_setting, :column_names)).map(&:to_s)
      sanitized_names = selected_names.select { |name| available_names.include?(name) }
      selected_item_list_names = Array(params.dig(:cosmosys_setting, :item_list_column_names)).map(&:to_s)
      sanitized_item_list_names = selected_item_list_names.select { |name| available_names.include?(name) }
      raw_presentations_param = params.dig(:cosmosys_setting, :field_presentations)
      raw_presentations =
        case raw_presentations_param
        when ActionController::Parameters
          raw_presentations_param.to_unsafe_h
        when Hash
          raw_presentations_param
        else
          {}
        end
      sanitized_presentations = sanitized_names.each_with_object({}) do |name, result|
        mode = raw_presentations[name].to_s
        result[name] = Cosmosys::MainReportFieldRegistry.valid_representation_mode?(mode) ? mode : Cosmosys::MainReportFieldRegistry::DEFAULT_REPRESENTATION_MODE
      end
      report_options = Cosmosys::MainReportSettings.normalize_options(params.dig(:cosmosys_setting, :report_options))
      landscape_scale_threshold = params.dig(:cosmosys_setting, :landscape_scale_threshold).to_i.clamp(0, 100)
      raw_layout_mode = params.dig(:cosmosys_setting, :combined_layout_mode).to_s
      layout_mode =
        if Cosmosys::CombinedDiagramRenderer.valid_layout_mode?(raw_layout_mode)
          raw_layout_mode
        else
          Cosmosys::CombinedDiagramRenderer::DEFAULT_LAYOUT_MODE
        end
      raw_render_variant = params.dig(:cosmosys_setting, :combined_render_variant).to_s
      render_variant =
        if Cosmosys::CombinedDiagramRenderer.valid_render_variant?(raw_render_variant)
          raw_render_variant
        else
          Cosmosys::CombinedDiagramRenderer::DEFAULT_RENDER_VARIANT
        end

      setting = @project.cosmosys_report_setting_record || @project.build_cosmosys_report_setting_record
      setting.assign_report_settings(
        columns: sanitized_names,
        field_presentations: sanitized_presentations,
        options: report_options,
        landscape_scale_threshold: landscape_scale_threshold,
        item_list_columns: sanitized_item_list_names
      )
      setting.assign_combined_layout_mode(layout_mode)
      setting.assign_combined_render_variant(render_variant)
      setting.save!

      flash[:notice] = l(:notice_successful_update)
      redirect_to settings_project_path(@project, tab: 'cosmosys')
    end

    private

    def update_project_profile!
      profile_key = Cosmosys::ProjectProfileRegistry.normalize_key(params.dig(:cosmosys_setting, :project_profile))
      raise ActiveRecord::RecordInvalid, @project unless Cosmosys::ProjectProfileRegistry.registered?(profile_key)
      profile_changed = @project.csys_project_profile != profile_key

      root_key = params.dig(:cosmosys_setting, :root_tracker_key).to_s
      root_key = nil if root_key == 'inherit'
      allowed_keys = ['free'] + Tracker.where(id: @project.tracker_ids).where.not(csys_key: nil).pluck(:csys_key)
      root_key = nil unless root_key.nil? || allowed_keys.include?(root_key)
      @project.csys_project_profile = profile_key
      language = params.dig(:cosmosys_setting, :language).to_s
      @project.csys_language = Cosmosys::ProjectLanguage.normalize(language, allow_blank: true)
      @project.csys_report_code = params.dig(:cosmosys_setting, :report_code).to_s.strip.presence
      @project.csys_report_export_format = Cosmosys::ReportFormat.normalize(
        params.dig(:cosmosys_setting, :report_export_format),
        allow_blank: true
      )
      @project.csys_root_tracker_key = root_key
      template_asset_id = params.dig(:cosmosys_setting, :ods_template_asset_id).presence
      @project.cosmosys_ods_template_asset = template_asset_id ? Cosmosys::TemplateAsset.available_ods.find(template_asset_id) : nil
      assign_report_template!
      @project.csys_project_passphrase = params.dig(:cosmosys_setting, :project_passphrase).to_s.presence
      @project.cosmosys_enable_required_trackers!
      @project.save!
      @project.cosmosys_apply_profile_module_defaults! if profile_changed
    end

    def assign_report_template!
      selection = params.dig(:cosmosys_setting, :report_template).to_s
      @project.cosmosys_report_template_asset = nil
      @project.csys_report_template_key = nil
      case selection
      when /\Aasset:(\d+)\z/
        @project.cosmosys_report_template_asset = Cosmosys::TemplateAsset.available_reports.find(Regexp.last_match(1))
      when /\Abuiltin:([a-z0-9_]+)\z/
        key = Regexp.last_match(1)
        raise ActiveRecord::RecordNotFound unless Cosmosys::ReportTemplateCatalog.registered?(key)
        @project.csys_report_template_key = key
      end
    end

    def authorize_project_settings
      deny_access unless User.current.allowed_to?(:edit_project, @project)
    end
  end
end
