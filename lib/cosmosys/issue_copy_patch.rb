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
      end
    end

  end
end
