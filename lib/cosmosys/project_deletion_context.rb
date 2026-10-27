module Cosmosys
  class ProjectDeletionContext
    KEY = :cosmosys_project_deletion_context
    attr_reader :project_ids

    def self.current = ActiveSupport::IsolatedExecutionState[KEY]

    def initialize(project)
      @project = project
      @project_ids = []
    end

    def validate!
      @project_ids = []
      unless Cosmosys::ProjectTreeAudit.new.call.fetch(:healthy)
        raise ActiveRecord::RecordNotDestroyed.new(I18n.t(:error_cosmosys_project_tree_unhealthy), @project)
      end
      pending = [@project.id]
      until pending.empty?
        @project_ids.concat(pending)
        pending = Project.where(parent_id: pending).where.not(id: project_ids).pluck(:id)
      end
      issues = Issue.arel_table
      doomed = issues.alias('cosmosys_doomed')
      descendants = issues.join(doomed).on(
        issues[:root_id].eq(doomed[:root_id])
          .and(issues[:lft].gt(doomed[:lft]))
          .and(issues[:rgt].lt(doomed[:rgt]))
      ).join_sources
      external_children = Issue.where.not(project_id: project_ids)
                               .joins(descendants).where(doomed[:project_id].in(project_ids))
      if external_children.exists?
        raise ActiveRecord::RecordNotDestroyed.new(I18n.t(:error_cosmosys_project_external_children), @project)
      end
      Issue.where(project_id: project_ids).includes(:tracker).find_each do |datum|
        next unless datum.cosmosys_defines_project_data?

        usages = Cosmosys::ProjectDataUsageScanner.new(datum).call(limit: 4, excluding_project_ids: project_ids)
        next if usages.empty?

        references = usages.map { |usage| "##{usage.issue.id} (#{usage.attribute})" }.join(', ')
        raise ActiveRecord::RecordNotDestroyed.new(
          I18n.t(:text_cosmosys_project_data_in_use, references: references), @project
        )
      end
      self
    end

    def with
      previous = self.class.current
      result = nil
      Project.transaction(requires_new: true) do
        # Same instance-wide row-lock ordering as Redmine's nested-set writer.
        Project.reorder(:id).lock.ids
        validate!
        ActiveSupport::IsolatedExecutionState[KEY] = self
        result = yield
        raise ActiveRecord::Rollback unless result
        audit = Cosmosys::ProjectTreeAudit.new.call
        unless audit.fetch(:healthy)
          raise ActiveRecord::RecordNotDestroyed.new(I18n.t(:error_cosmosys_project_tree_unhealthy), @project)
        end
      end
      result
    ensure
      ActiveSupport::IsolatedExecutionState[KEY] = previous
    end
  end
end
