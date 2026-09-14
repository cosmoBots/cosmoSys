require 'set'

module Cosmosys
  class ProjectCopyFinalizer
    attr_reader :context, :source, :destination

    def initialize(context, destination)
      @context = context
      @source = context.source_project
      @destination = destination
    end

    def call
      context.destination_project = destination
      apply_profile!
      materialize_snapshot_contents!
      reconcile_external_relations!
      copy_report_settings!
      context.summary.merge!(summary)
      context
    end

    private

    def apply_profile!
      raise ProjectCopyError, "Unknown project profile #{context.profile_key}" unless Cosmosys::ProjectProfileRegistry.registered?(context.profile_key)

      destination.update_columns(
        csys_project_profile: context.profile_key,
        csys_root_tracker_key: source.csys_root_tracker_key,
        csys_ods_template_asset_id: source.csys_ods_template_asset_id,
        csys_report_template_asset_id: source.csys_report_template_asset_id,
        csys_report_template_key: source.csys_report_template_key,
        csys_language: source.csys_language,
        csys_report_code: source.csys_report_code,
        csys_report_export_format: source.csys_report_export_format,
        cslast_id: destination.issues.maximum(:csidnum).to_i
      )
      destination.cosmosys_enable_required_trackers!
    end

    def materialize_snapshot_contents!
      return unless context.snapshot_source

      Cosmosys::ProjectSnapshotMaterializer.new(
        context.snapshot_source,
        user: context.user,
        attributes: {
          identity_mode: context.identity_mode, copy_mode: context.mode,
          project_data_conflict_policy: effective_copy_plan.destination_attributes['project_data_conflict_policy']
        }
      ).materialize_into!(
        destination,
        selected_parts: context.selected_parts,
        copy_context: context
      )
    end

    def reconcile_external_relations!
      copied_ids = context.issue_map.values.map(&:id).to_set
      removed = 0
      IssueRelation.where('issue_from_id IN (?) OR issue_to_id IN (?)', copied_ids, copied_ids).find_each do |relation|
        next if copied_ids.include?(relation.issue_from_id) && copied_ids.include?(relation.issue_to_id)
        relation.destroy!
        removed += 1
      end

      restored = Hash.new(0)
      Array(effective_copy_plan.external_relations).each do |entry|
        classification = entry.fetch(:classification)
        unless %w[retain_original remap_by_csid].include?(classification)
          restored[classification] += 1
          next
        end

        local_issue = context.issue_map.fetch(entry.fetch(:local_source_id))
        target_issue = Issue.find(entry.fetch(:target_id))
        attributes = { relation_type: entry.fetch(:relation_type), delay: entry[:delay] }
        relation = if entry.fetch(:local_side) == 'from'
                     IssueRelation.new(attributes.merge(issue_from: local_issue, issue_to: target_issue))
                   else
                     IssueRelation.new(attributes.merge(issue_from: target_issue, issue_to: local_issue))
                   end
        relation.save!
        restored[classification] += 1
      end
      context.summary[:external_relations_removed_from_native_copy] = removed
      context.summary[:external_relations] = restored
    end

    def effective_copy_plan
      context.copy_plan ||= ProjectCopyPlan.new(
        source: source,
        user: context.user,
        context: context,
        destination_attributes: {
          'name' => destination.name,
          'identifier' => destination.identifier,
          'cscode' => destination.cscode,
          'parent_id' => destination.parent_id
        }
      )
    end

    def copy_report_settings!
      return unless source.cosmosys_report_setting_record

      attributes = source.cosmosys_report_setting_record.attributes.except('id', 'project_id', 'created_at', 'updated_at')
      destination.create_cosmosys_report_setting_record!(attributes)
    end

    def summary
      {
        mode: context.mode,
        identity_mode: context.identity_mode,
        items: context.issue_map.length,
        documents: context.document_map.length,
        catalog_refs: context.summary.fetch(:catalog_refs, 0),
        members: destination.members.count
      }
    end
  end
end
