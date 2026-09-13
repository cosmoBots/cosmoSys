module Cosmosys
  class ProjectTreeCopyExecutor
    SNAPSHOT_PARTS = %w[issues documents].freeze

    attr_reader :plan, :context, :projects

    def initialize(plan)
      @plan = plan
      @context = plan.context
    end

    def call
      ActiveRecord::Base.transaction do
        materializer = ProjectSnapshotMaterializer.new(
          plan.snapshot_source,
          user: plan.user,
          attributes: plan.materialization_plan.attributes.merge(
            'identity_mode' => context.identity_mode,
            'copy_mode' => context.mode
          )
        )
        @projects = materializer.materialize_projects!(selected_parts: context.selected_parts) do |destinations|
          copy_native_parts!(destinations)
        end
        archive_destinations! if context.archive?
        root = destination_root
        context.destination_project = root
        context.summary.merge!(summary)
        root
      end
    rescue StandardError
      @projects = nil
      raise
    end

    private

    def copy_native_parts!(destinations)
      native_parts = context.selected_parts - SNAPSHOT_PARTS
      source_by_key = plan.selected_projects.index_by { |project| "project:#{project.id}" }
      destinations.each do |key, destination|
        source = source_by_key.fetch(key)
        copy_project_configuration!(source, destination)
        destination.copy(source, only: native_parts)
        copy_report_settings!(source, destination)
      end
    end

    def copy_project_configuration!(source, destination)
      destination.issue_custom_fields = source.issue_custom_fields
      destination.custom_values = source.custom_values.map(&:dup)
      destination.is_public = source.is_public
      destination.inherit_members = source.inherit_members
      destination.homepage = source.homepage
      destination.save!
    end

    def copy_report_settings!(source, destination)
      return unless source.cosmosys_report_setting_record

      attributes = source.cosmosys_report_setting_record.attributes.except(
        'id', 'project_id', 'created_at', 'updated_at'
      )
      destination.create_cosmosys_report_setting_record!(attributes)
    end

    def archive_destinations!
      projects.values.sort_by { |project| -project.lft.to_i }.each(&:archive!)
    end

    def destination_root
      row = plan.destination_projects.find { |entry| entry[:parent_key].blank? }
      projects.fetch(row.fetch(:key))
    end

    def summary
      content = plan.snapshot_source.manifest.fetch('content')
      {
        projects: projects.length,
        items: context.copying?('issues') ? content.fetch('projects').sum { |entry| entry.fetch('items').length } : 0,
        documents: context.copying?('documents') ? content.fetch('projects').sum { |entry| entry.fetch('documents').length } : 0,
        relations: context.copying?('issues') ? content.fetch('relations').length : 0
      }
    end
  end
end
