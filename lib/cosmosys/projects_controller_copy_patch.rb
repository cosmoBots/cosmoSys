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
      preflight_cosmosys_copy_identity!(context)
      Cosmosys::ProjectCopyContext.with(context) { super }
      if context.destination_project&.persisted?
        context.destination_project.archive! if context.archive?
        flash[:notice] = I18n.t(:notice_cosmosys_project_copy_complete, summary: context.summary.to_json)
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

    def preflight_cosmosys_copy_identity!(context)
      return unless context.identity_mode == 'preserve' && context.copying?('issues')

      attributes = params[:project] || {}
      destination_cscode = attributes[:cscode].to_s
      unless destination_cscode.casecmp(context.source_project.cscode.to_s).zero?
        raise Cosmosys::ProjectCopyError, I18n.t(:error_cosmosys_preserve_csid_project_code)
      end

      parent = Project.find_by(id: attributes[:parent_id].presence)
      return unless parent

      source_csids = context.source_project.issues.where.not(csid: nil).pluck(:csid)
      collisions = Issue.where(project_id: parent.root.self_and_descendants.select(:id))
                        .where('LOWER(csid) IN (?)', source_csids.map(&:downcase)).pluck(:csid)
      return if collisions.empty?

      raise Cosmosys::ProjectCopyError,
            I18n.t(:error_cosmosys_preserve_csid_collision, csids: collisions.sort.join(', '))
    end

    def cleanup_cosmosys_copy_destination(context, source)
      candidate = context&.destination_project || @project
      candidate.destroy if candidate&.persisted? && candidate.id != source&.id
    end

    def prepare_cosmosys_copy_form_after_error(source, error)
      @source_project = source
      @issue_custom_fields = IssueCustomField.sorted.to_a
      @trackers = Tracker.sorted.to_a
      @project = Project.new
      @project.safe_attributes = params[:project]
      @project.errors.add(:base, error.message)
      flash.now[:error] = error.message
    end
  end
end
