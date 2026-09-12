require_dependency 'issue'

module Cosmosys
  module IssueCopyPatch
    def copy_from(arg, options = {})
      source = arg.is_a?(Issue) ? arg : Issue.visible.find(arg)
      super.tap do
        self.cosmosys_preferred_report_diagram = source.cosmosys_preferred_report_diagram
        self.csid = nil
        self.csidnum = nil
        self.csposition = nil
        @cosmosys_copy_source_id = source.id
        defer_cosmosys_issue_references(source)
      end
    end

    private

    def defer_cosmosys_issue_references(source)
      context = Cosmosys::ProjectCopyContext.current
      return unless context&.source_project == source.project

      Cosmosys::ProjectCopyReferenceRegistry.attributes.each do |attribute|
        next unless has_attribute?(attribute) && source.has_attribute?(attribute)

        context.defer_issue_reference(source.id, attribute, source[attribute])
        self[attribute] = nil
      end
    end
  end
end
