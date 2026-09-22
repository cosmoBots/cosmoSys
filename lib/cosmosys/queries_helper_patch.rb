require_dependency 'queries_helper'

module Cosmosys
  module QueriesHelperPatch
    def render_cosmosys_report_columns_selection(columns:, selected_names:, name:)
      eligible_columns = Array(columns).reject(&:frozen?)
      columns_by_name = eligible_columns.index_by { |column| column.name.to_s }
      selected_columns = Array(selected_names).filter_map { |column_name| columns_by_name[column_name.to_s] }
      available_columns = eligible_columns.reject { |column| selected_columns.include?(column) }

      render partial: 'cosmosys/shared/report_columns', locals: {
        available_columns: available_columns,
        selected_columns: selected_columns,
        tag_name: "#{name}[]"
      }
    end

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
