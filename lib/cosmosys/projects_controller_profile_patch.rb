require_dependency 'projects_controller'

module Cosmosys
  module ProjectsControllerProfilePatch
    def new
      return super unless request.get? && request.format.html?

      profile_key = requested_cosmosys_project_profile
      unless profile_key && Cosmosys::ProjectProfileRegistry.registered?(profile_key)
        @cosmosys_parent_id = params.dig(:project, :parent_id).presence || params[:parent_id].presence
        @cosmosys_project_profiles = Cosmosys::ProjectProfileRegistry.all
        render template: 'cosmosys/projects/select_profile'
        return
      end

      super
      @project.csys_project_profile = profile_key
      unless params[:project].respond_to?(:key?) && params[:project].key?(:enabled_module_names)
        @project.enabled_module_names = @project.cosmosys_profile_default_module_names
      end
    end

    def create
      project_params = params[:project]
      if project_params.respond_to?(:key?) && project_params.key?(:enabled_module_names)
        project_params[:csys_modules_explicit] = '1'
      end
      super
    end

    private

    def requested_cosmosys_project_profile
      raw = params[:project_profile].presence || params.dig(:project, :csys_project_profile).presence
      raw && Cosmosys::ProjectProfileRegistry.normalize_key(raw)
    end
  end
end
