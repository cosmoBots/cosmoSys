module Cosmosys
  module ProjectDeletionPatch
    def destroy
      return super unless persisted?

      if Cosmosys::ProjectDeletionContext.current
        unless Cosmosys::ProjectDeletionContext.current.project_ids.include?(id)
          raise ActiveRecord::RecordNotDestroyed.new(I18n.t(:error_cosmosys_project_tree_unhealthy), self)
        end
        # Redmine's destroy_children ignores false. Raise to roll back the
        # whole subtree instead of shifting its nested set after a child failed.
        result = super
        unless result
          raise ActiveRecord::RecordNotDestroyed.new(errors.full_messages.join(', '), self)
        end
        return result
      end

      begin
        Cosmosys::ProjectDeletionContext.new(self).with { super }
      rescue ActiveRecord::RecordNotDestroyed => error
        errors.add(:base, I18n.t(:error_cosmosys_project_deletion_failed, reason: error.message))
        Rails.logger.warn("[cosmosys.project_deletion] project_id=#{id} #{errors.full_messages.join(', ')}")
        false
      end
    end
  end

  module ProjectDeletionSchedulePatch
    def schedule(project, **options)
      Project.transaction do
        Project.reorder(:id).lock.ids
        Cosmosys::ProjectDeletionContext.new(project).validate!
        super
      end
    end
  end

  module ProjectsDeletionSchedulePatch
    def schedule(projects, **options)
      Project.transaction do
        Project.reorder(:id).lock.ids
        projects.each { |project| Cosmosys::ProjectDeletionContext.new(project).validate! }
        super
      end
    end
  end

  module ProjectsControllerDeletionPatch
    def destroy
      super
    rescue ActiveRecord::RecordNotDestroyed => error
      cosmosys_render_deletion_error(error)
    end

    def bulk_destroy
      super
    rescue ActiveRecord::RecordNotDestroyed => error
      cosmosys_render_deletion_error(error)
    end

    private

    def cosmosys_render_deletion_error(error)
      respond_to do |format|
        format.html do
          flash[:error] = error.message
          redirect_to(User.current.admin? ? admin_projects_path : projects_path)
        end
        format.api { render plain: error.message, status: :unprocessable_entity }
      end
    end
  end
end
