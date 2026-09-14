require_dependency File.expand_path('ods_item_field_registry', __dir__)

module Cosmosys
  module OdsFields
    module_function

    def register!
      unless Cosmosys::OdsItemFieldRegistry.names.include?('csys_value')
        Cosmosys::OdsItemFieldRegistry.register(
          'csys_value',
          writer: ->(issue, value) { issue.csys_value = value if issue.cosmosys_defines_project_data? }
        )
      end

      unless Cosmosys::OdsItemFieldRegistry.names.include?('report_placeholder_kind')
        Cosmosys::OdsItemFieldRegistry.register(
          'report_placeholder_kind',
          reader: ->(issue) { issue.csys_report_placeholder_kind },
          writer: ->(issue, value) { issue.csys_report_placeholder_kind = value.to_s.presence }
        )
      end

      name = 'preferred_report_diagram'
      return if Cosmosys::OdsItemFieldRegistry.names.include?(name)

      Cosmosys::OdsItemFieldRegistry.register(
        name,
        reader: ->(issue) { issue.cosmosys_preferred_report_diagram },
        writer: lambda do |issue, value|
          issue.cosmosys_preferred_report_diagram = value.to_s.strip.presence || 'combined'
        end
      )
    end
  end
end

Cosmosys::OdsFields.register!
