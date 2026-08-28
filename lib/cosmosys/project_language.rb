module Cosmosys
  module ProjectLanguage
    DEFAULT = 'en'

    module_function

    def available
      I18n.available_locales.map(&:to_s)
    end

    def normalize(value, allow_blank: false)
      language = value.to_s
      return nil if allow_blank && language.blank?

      available.include?(language) ? language : DEFAULT
    end

    def instance_default
      normalize((Setting.plugin_cosmosys || {})['official_project_language'])
    end
  end
end
