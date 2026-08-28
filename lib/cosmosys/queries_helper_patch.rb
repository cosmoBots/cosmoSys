require_dependency 'queries_helper'

module Cosmosys
  module QueriesHelperPatch
    def column_value(column, item, value)
      if column.name == :csid && item.is_a?(Issue) && item.respond_to?(:cosmosys_display_ref)
        return link_to(item.cosmosys_display_ref, issue_path(item), class: item.css_classes)
      end

      super
    end
  end
end
