module Cosmosys
  class ProjectDataReportScanner
    def initialize(report, user:)
      @report = report
      @dictionary = ProjectDataDictionary.current(project: report.project, user: user)
    end

    def call
      report.sections.each { |section| scan_section(section) }
      dictionary
    end

    private

    attr_reader :report, :dictionary

    def scan_section(section)
      dictionary.resolve(section.issue.description) if report.options['description']
      (section.metadata_fields + section.body_fields).select(&:rich_text).each do |field|
        dictionary.resolve(field.value)
      end
      section.children.each { |child| scan_section(child) }
    end
  end
end
