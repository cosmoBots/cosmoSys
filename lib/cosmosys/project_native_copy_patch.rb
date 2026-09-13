require_dependency 'project'

module Cosmosys
  module ProjectNativeCopyPatch
    SNAPSHOT_PARTS = %w[issues documents].freeze

    def copy(project, options = {})
      context = Cosmosys::ProjectCopyContext.current
      return super unless context&.source_project == project

      context.snapshot_source = Cosmosys::ProjectSnapshotCapture.new(
        project, user: context.user, projects: [project.id]
      )
      filtered = options.dup
      selected = options[:only].nil? ?
        %w[members wiki versions issue_categories issues queries boards documents] : Array(options[:only]).map(&:to_s)
      filtered[:only] = selected - SNAPSHOT_PARTS
      super(project, filtered)
    end

  end
end
