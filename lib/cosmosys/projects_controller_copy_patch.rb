require_dependency 'projects_controller'

module Cosmosys
  module ProjectsControllerCopyPatch
    def copy
      return super if request.get?

      source = Project.find(params[:id])
      copy_params = params[:cosmosys_copy] || {}
      context = Cosmosys::ProjectCopyContext.new(
        source_project: source,
        user: User.current,
        mode: copy_params[:mode],
        selected_parts: params[:only],
        profile_key: source.csys_project_profile,
        archive: copy_params[:archive]
      )
      Cosmosys::ProjectCopyContext.with(context) { super }
      if context.destination_project&.persisted?
        context.destination_project.archive! if context.archive?
        flash[:notice] = I18n.t(:notice_cosmosys_project_copy_complete, summary: context.summary.to_json)
      end
    rescue Cosmosys::ProjectCopyError => error
      cleanup_cosmosys_copy_destination(context, source)
      flash[:error] = error.message
      redirect_to action: :copy, id: params[:id]
    rescue StandardError
      cleanup_cosmosys_copy_destination(context, source)
      raise
    end

    private

    def cleanup_cosmosys_copy_destination(context, source)
      candidate = context&.destination_project || @project
      candidate.destroy if candidate&.persisted? && candidate.id != source&.id
    end
  end
end
