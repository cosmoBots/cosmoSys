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
          Rspreadsheet::Tools.set_ns_attribute(sheet.xmlnode, 'table', 'display', 'false') if name.match?(/Ctrl\z/i)
        elsif name.match?(PROJECT_SHEET)
          sheet.protect(password: project_passphrase, algorithm: :sha1)
        end
      end
      workbook
    end
  end
end
