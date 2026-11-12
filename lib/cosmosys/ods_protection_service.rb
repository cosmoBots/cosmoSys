require_relative 'ods_item_field_registry'

module Cosmosys
  class OdsProtectionService
    INSTANCE_SHEET = /\A(?:cosmosys|_?dsmcalc.*|(?:items|documents|catalog)ctrl)\z/i
    PROJECT_SHEET = /\Adict\z/i

    def self.apply!(workbook, project:)
      instance_passphrase = Setting.plugin_cosmosys['instance_passphrase'].to_s.presence || 'admin'
      project_passphrase = project.cosmosys_effective_project_passphrase

      workbook.worksheet_names.each do |name|
        sheet = workbook.worksheets(name)
        if name.match?(INSTANCE_SHEET)
          sheet.protect(password: instance_passphrase, algorithm: :sha1)
          hide_sheet!(workbook, sheet) if name.match?(/\Acosmosys\z|Ctrl\z/i)
        elsif name.match?(PROJECT_SHEET) || OdsItemFieldRegistry.fields.values.any? { |field| field.dictionary_sheet == name }
          sheet.protect(password: project_passphrase, algorithm: :sha1)
        end
      end
      workbook
    end

    # Visibility is a table-style property, not an attribute of table:table.
    # A private style avoids hiding other sheets sharing the original style.
    def self.hide_sheet!(workbook, sheet)
      tools = Rspreadsheet::Tools
      styles = workbook.xmldoc.find_first('//office:automatic-styles')
      unless styles
        styles = tools.prepare_ns_node('office', 'automatic-styles')
        workbook.xmldoc.find_first('//office:body').prev = styles
      end
      table_styles = styles.find('./style:style').select { |node| tools.get_ns_attribute_value(node, 'style', 'family') == 'table' }
      original_name = tools.get_ns_attribute_value(sheet.xmlnode, 'table', 'style-name')
      original = table_styles.find { |node| tools.get_ns_attribute_value(node, 'style', 'name') == original_name }
      shared = workbook.worksheet_names.any? do |name|
        name != sheet.name && tools.get_ns_attribute_value(workbook.worksheets(name).xmlnode, 'table', 'style-name') == original_name
      end
      style = original if original_name.to_s.start_with?('cosmosys_hidden_') && !shared
      unless style
        style_name = "cosmosys_hidden_#{workbook.worksheet_names.index(sheet.name)}"
        style_name += '_' while table_styles.any? { |node| tools.get_ns_attribute_value(node, 'style', 'name') == style_name }
        style = original ? original.copy(true) : tools.prepare_ns_node('style', 'style')
        tools.set_ns_attribute(style, 'style', 'name', style_name)
        tools.set_ns_attribute(style, 'style', 'family', 'table')
        tools.set_ns_attribute(style, 'style', 'parent-style-name', original_name) if !original && original_name.present?
        styles << style
      end
      properties = style.find_first('./style:table-properties')
      unless properties
        properties = tools.prepare_ns_node('style', 'table-properties')
        style << properties
      end
      tools.set_ns_attribute(properties, 'table', 'display', 'false')
      tools.set_ns_attribute(sheet.xmlnode, 'table', 'style-name', tools.get_ns_attribute_value(style, 'style', 'name'))
      tools.remove_ns_attribute(sheet.xmlnode, 'table', 'display')
    end
    private_class_method :hide_sheet!
  end
end
