module Cosmosys
  class ProjectReportSetting < ActiveRecord::Base
    self.table_name = 'cosmosys_project_report_settings'

    belongs_to :project

    validates :project_id, presence: true, uniqueness: true

    def report_payload
      parsed =
        case column_names
        when Hash
          column_names
        when String
          JSON.parse(column_names)
        when Array
          { 'columns' => column_names }
        else
          {}
        end

      parsed = { 'columns' => parsed } if parsed.is_a?(Array)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def column_names_array
      Array(report_payload['columns']).map(&:to_s).reject(&:blank?)
    end

    def column_names_array=(names)
      update_report_payload(columns: Array(names).map(&:to_s).reject(&:blank?))
    end

    def field_presentations_hash
      raw = report_payload['field_presentations']
      return {} unless raw.is_a?(Hash)

      raw.transform_keys(&:to_s).transform_values(&:to_s)
    end

    def field_presentations_hash=(modes)
      update_report_payload(field_presentations: Hash(modes).transform_keys(&:to_s).transform_values(&:to_s))
    end

    def report_options_hash
      Cosmosys::MainReportSettings.normalize_options(report_payload['options'])
    end

    def landscape_scale_threshold
      report_payload.fetch('landscape_scale_threshold', 55).to_i.clamp(0, 100)
    end

    def assign_report_settings(columns:, field_presentations:, options: nil, landscape_scale_threshold: nil)
      update_report_payload(
        columns: Array(columns).map(&:to_s).reject(&:blank?),
        field_presentations: Hash(field_presentations).transform_keys(&:to_s).transform_values(&:to_s),
        options: options,
        landscape_scale_threshold: landscape_scale_threshold
      )
    end

    def combined_layout_mode
      report_payload['combined_layout_mode'].to_s
    end

    def combined_layout_mode=(mode)
      update_report_payload(combined_layout_mode: mode.to_s)
    end

    def assign_combined_layout_mode(mode)
      old_mode = combined_layout_mode
      update_report_payload(combined_layout_mode: mode.to_s)
      invalidate_combined_diagram_cache! if old_mode != mode.to_s
    end

    def combined_render_variant
      report_payload['combined_render_variant'].to_s
    end

    def combined_render_variant=(variant)
      update_report_payload(combined_render_variant: variant.to_s)
    end

    def assign_combined_render_variant(variant)
      old_variant = combined_render_variant
      update_report_payload(combined_render_variant: variant.to_s)
      invalidate_combined_diagram_cache! if old_variant != variant.to_s
    end

    private

    def invalidate_combined_diagram_cache!
      Cosmosys::Diagram.where(project_id: project_id, kind: 'project_combined').update_all(state: 'obsolete', updated_at: Time.current)
      Cosmosys::Diagram.where(issue_id: Issue.where(project_id: project_id).select(:id), kind: 'combined').update_all(state: 'obsolete', updated_at: Time.current)
    end

    def update_report_payload(columns: nil, field_presentations: nil, options: nil, combined_layout_mode: nil, combined_render_variant: nil, landscape_scale_threshold: nil)
      payload = report_payload
      payload['columns'] = columns unless columns.nil?
      payload['field_presentations'] = field_presentations unless field_presentations.nil?
      payload['options'] = options unless options.nil?
      payload['combined_layout_mode'] = combined_layout_mode unless combined_layout_mode.nil?
      payload['combined_render_variant'] = combined_render_variant unless combined_render_variant.nil?
      payload['landscape_scale_threshold'] = landscape_scale_threshold.to_i.clamp(0, 100) unless landscape_scale_threshold.nil?
      self.column_names = payload.to_json
    end
  end
end
