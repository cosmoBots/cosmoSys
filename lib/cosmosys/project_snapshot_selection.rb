module Cosmosys
  class ProjectSnapshotSelection
    attr_reader :context, :user

    def initialize(context, user:)
      @context = context
      @user = user
    end

    def available_projects
      @available_projects ||= tree_root(context).self_and_descendants
                                      .select { |project| project.visible?(user) }
                                      .sort_by { |project| [project.lft.to_i, project.id] }
    end

    def selectable?(project)
      user&.admin? || user&.allowed_to?(:edit_project, project)
    end

    def resolve(ids)
      requested = Array(ids).filter_map { |id| Integer(id, exception: false) }.uniq
      raise ArgumentError, I18n.t(:error_cosmosys_snapshot_empty_selection) if requested.empty?
      projects = Project.where(id: requested).to_a

      raise Unauthorized unless projects.length == requested.length
      raise Unauthorized unless projects.all? { |project| project.visible?(user) }
      root_id = tree_root(context).id
      raise ArgumentError, I18n.t(:error_cosmosys_snapshot_mixed_roots) unless projects.all? { |project| tree_root(project).id == root_id }
      raise Unauthorized unless projects.all? { |project| selectable?(project) }
      projects.sort_by { |project| [project.lft.to_i, project.id] }
    end

    private

    def tree_root(project)
      # Nested-set bounds can change while a copy form remains open (for
      # example when another root project is created). Always resolve the root
      # from current bounds before comparing the selected projects.
      project.reload
      project.root || project
    end
  end
end
