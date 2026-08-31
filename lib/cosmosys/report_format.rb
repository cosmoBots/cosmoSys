module Cosmosys
  module ReportFormat
    FORMATS = %w[odt docx pdf].freeze
    DEFAULT = 'odt'.freeze

    module_function

    def options
      FORMATS
    end

    def normalize(value, allow_blank: false)
      candidate = value.to_s.downcase
      return nil if allow_blank && candidate.blank?

      FORMATS.include?(candidate) ? candidate : DEFAULT
    end

    def global_default
      normalize((Setting.plugin_cosmosys || {})['report_export_format'])
    end
  end
end
