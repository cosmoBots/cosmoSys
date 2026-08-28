require_dependency File.expand_path('ods_item_field_registry', __dir__)

module Cosmosys
  module OdsFields
    module_function

    def register!
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
