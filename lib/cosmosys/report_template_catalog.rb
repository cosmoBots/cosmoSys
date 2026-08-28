module Cosmosys
  module ReportTemplateCatalog
    Template = Struct.new(:key, :label, :path, keyword_init: true)

    DEFAULT_KEY = 'a4_portrait'.freeze
    TEMPLATES = [
      Template.new(key: 'a4_portrait', label: 'A4 — Portrait', path: 'plugins/cosmosys/assets/report_export/templates/A4/Portrait/report_template.odt'),
      Template.new(key: 'a4_landscape', label: 'A4 — Landscape', path: 'plugins/cosmosys/assets/report_export/templates/A4/Landscape/report_template.odt'),
      Template.new(key: 'a3_portrait', label: 'A3 — Portrait', path: 'plugins/cosmosys/assets/report_export/templates/A3/Portrait/report_template.odt'),
      Template.new(key: 'a3_landscape', label: 'A3 — Landscape', path: 'plugins/cosmosys/assets/report_export/templates/A3/Landscape/report_template.odt')
    ].to_h { |template| [template.key, template.freeze] }.freeze

    module_function

    def fetch(key) = TEMPLATES[key.to_s]
    def all = TEMPLATES.values
    def registered?(key) = TEMPLATES.key?(key.to_s)
    def default = TEMPLATES.fetch(DEFAULT_KEY)
  end
end
