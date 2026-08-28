module Cosmosys
  module MainReportSettings
    DEFAULTS = {
      'main_report_default_columns' => [],
      'main_report_field_presentations' => {},
      'main_report_options' => {
        'description' => '1',
        'preferred_diagram' => '1',
        'combined_diagram' => '0',
        'hierarchy_diagram' => '0',
        'dependency_diagram' => '0',
        'item_url_link' => '0',
        'info_url_link' => '0'
      }
    }.freeze

    OPTION_NAMES = DEFAULTS.fetch('main_report_options').keys.freeze

    module_function

    def plugin_settings
      DEFAULTS.merge((Setting.plugin_cosmosys || {}).stringify_keys)
    end

    def global_column_names(user: User.current)
      available_names = Cosmosys::MainReportFieldRegistry.available_column_names(user: user)
      saved_names = normalize_string_array(plugin_settings['main_report_default_columns'])
      selected_names = saved_names.select { |name| available_names.include?(name) }

      selected_names.presence || Cosmosys::MainReportFieldRegistry.default_column_names(user: user)
    end

    def global_field_presentations(user: User.current)
      selected_names = global_column_names(user: user)
      saved_modes = normalize_string_hash(plugin_settings['main_report_field_presentations'])

      selected_names.each_with_object({}) do |name, result|
        mode = saved_modes[name].to_s
        result[name] = Cosmosys::MainReportFieldRegistry.valid_representation_mode?(mode) ? mode : Cosmosys::MainReportFieldRegistry::DEFAULT_REPRESENTATION_MODE
      end
    end

    def global_options
      normalize_options(plugin_settings['main_report_options'])
    end

    def normalize_options(value)
      raw = normalize_string_hash(value)
      raw['combined_diagram'] = raw['diagram'] if !raw.key?('combined_diagram') && raw.key?('diagram')
      defaults = DEFAULTS.fetch('main_report_options')
      defaults.keys.index_with do |name|
        ActiveModel::Type::Boolean.new.cast(raw.fetch(name, defaults.fetch(name)))
      end
    end

    def normalize_string_array(value)
      Array(value).map(&:to_s).reject(&:blank?)
    end

    def normalize_string_hash(value)
      case value
      when ActionController::Parameters
        value.to_unsafe_h.transform_keys(&:to_s).transform_values(&:to_s)
      when Hash
        value.transform_keys(&:to_s).transform_values(&:to_s)
      else
        {}
      end
    end
  end
end
