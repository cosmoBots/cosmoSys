require_dependency 'queries_helper'

module Cosmosys
  module QueriesHelperPatch
    def column_value(column, item, value)
      if column.name == :csid && item.is_a?(Issue) && item.respond_to?(:cosmosys_display_ref)
        return link_to(item.cosmosys_display_ref, issue_path(item), class: item.css_classes)
      end

      if item.is_a?(Issue) && column.respond_to?(:cosmosys_report_rich_text?) && column.cosmosys_report_rich_text?
        return value.present? ? content_tag('div', textilizable(item, column.name), class: 'wiki') : ''
      end

      super
    end
  end
end
