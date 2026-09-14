require_dependency 'projects_controller'

module Cosmosys
  module ProjectsControllerCopyPatch
    def copy
      if request.get?
        source = Project.find(params[:id])
        prepare_cosmosys_copy_projects(source)
        return super
      end

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
      selected_project_ids = Array(copy_params[:project_ids]).presence || [source.id]
      selected_project_ids = selected_project_ids.map(&:to_s).uniq
      raw_destination = params[:project] || {}
      raw_destination = raw_destination.to_unsafe_h if raw_destination.respond_to?(:to_unsafe_h)
      destination_attributes = raw_destination.to_h.merge(
        'project_data_conflict_policy' => copy_params[:project_data_conflict_policy]
      )
      plan = if selected_project_ids != [source.id.to_s]
               Cosmosys::ProjectTreeCopyPlan.new(
                 source: source, user: User.current, context: context,
                 destination_attributes: destination_attributes,
                 project_ids: selected_project_ids,
                 project_identifiers: copy_params[:project_identifiers]
               )
             else
               Cosmosys::ProjectCopyPlan.new(
                 source: source, user: User.current, context: context,
                 destination_attributes: destination_attributes
               )
             end
      raise Cosmosys::ProjectCopyError, plan.blocking_messages.join(' ') if plan.blocking_messages.any?

      confirmed_digest = plan.class.verified_digest(copy_params[:confirmed_plan])
      unless confirmed_digest && ActiveSupport::SecurityUtils.secure_compare(confirmed_digest, plan.digest)
        prepare_cosmosys_copy_review(source, plan)
        return render action: :copy
      end

      unless plan.executable?
        prepare_cosmosys_copy_review(source, plan)
        flash.now[:warning] = I18n.t(:text_cosmosys_copy_multi_preview_only)
        return render action: :copy, status: :unprocessable_entity
      end

      if plan.multi_project?
        destination = Cosmosys::ProjectTreeCopyExecutor.new(plan).call
        flash[:notice] = I18n.t(
          :notice_cosmosys_project_tree_copy_complete,
          project: destination.name,
          projects: context.summary.fetch(:projects),
          items: context.summary.fetch(:items),
          documents: context.summary.fetch(:documents),
          relations: context.summary.fetch(:relations)
        )
        return redirect_to project_path(destination)
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
      prepare_cosmosys_copy_projects(source)
      @issue_custom_fields = IssueCustomField.sorted.to_a
      @trackers = Tracker.sorted.to_a
      @project = Project.new
      @project.safe_attributes = params[:project]
    end

    def prepare_cosmosys_copy_projects(source)
      selection = Cosmosys::ProjectSnapshotSelection.new(source, user: User.current)
      @cosmosys_copy_projects = selection.available_projects.select { |project| selection.selectable?(project) }
    end
  end
end
