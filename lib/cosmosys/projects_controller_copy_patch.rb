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
        identity_mode: copy_params[:identity_mode],
        archive: copy_params[:archive]
      )
      plan = Cosmosys::ProjectCopyPlan.new(
        source: source,
        user: User.current,
        context: context,
        destination_attributes: params[:project] || {}
      )
      raise Cosmosys::ProjectCopyError, plan.blocking_messages.join(' ') if plan.blocking_messages.any?

      confirmed_digest = Cosmosys::ProjectCopyPlan.verified_digest(copy_params[:confirmed_plan])
      unless confirmed_digest && ActiveSupport::SecurityUtils.secure_compare(confirmed_digest, plan.digest)
        prepare_cosmosys_copy_review(source, plan)
        return render action: :copy
      end

      context.copy_plan = plan
      Cosmosys::ProjectCopyContext.with(context) { super }
      if context.destination_project&.persisted?
        context.destination_project.archive! if context.archive?
        flash[:notice] = Cosmosys::ProjectCopySummary.new(context).message
      end
    rescue Cosmosys::ProjectCopyError => error
      cleanup_cosmosys_copy_destination(context, source)
      prepare_cosmosys_copy_form_after_error(source, error)
      render action: :copy, status: :unprocessable_entity
    rescue StandardError
      cleanup_cosmosys_copy_destination(context, source)
      raise
    end

    private

    def cleanup_cosmosys_copy_destination(context, source)
      candidate = context&.destination_project || @project
      candidate.destroy if candidate&.persisted? && candidate.id != source&.id
    end

    def prepare_cosmosys_copy_form_after_error(source, error)
      prepare_cosmosys_copy_form(source)
      @project.errors.add(:base, error.message)
      flash.now[:error] = error.message
    end

    def prepare_cosmosys_copy_review(source, plan)
      prepare_cosmosys_copy_form(source)
      unless @project.valid?
        flash.now[:error] = @project.errors.full_messages.join(', ')
        return
      end
      @cosmosys_copy_plan = plan
    end

    def prepare_cosmosys_copy_form(source)
      @source_project = source
      @issue_custom_fields = IssueCustomField.sorted.to_a
      @trackers = Tracker.sorted.to_a
      @project = Project.new
      @project.safe_attributes = params[:project]
    end
  end
end
