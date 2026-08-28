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
      validate_native_copy!
      apply_mode!
      remove_external_relations!
      copy_document_references!
      rewrite_internal_references!
      copy_report_settings!
      context.summary.merge!(summary)
      context
    end

    private

    def apply_profile!
      raise ProjectCopyError, "Unknown project profile #{context.profile_key}" unless Cosmosys::ProjectProfileRegistry.registered?(context.profile_key)

      destination.update_columns(
        cosmosys_project_profile: context.profile_key,
        cosmosys_root_tracker_key: source.cosmosys_root_tracker_key,
        cosmosys_ods_template_asset_id: source.cosmosys_ods_template_asset_id,
        cosmosys_report_template_asset_id: source.cosmosys_report_template_asset_id,
        cosmosys_report_template_key: source.cosmosys_report_template_key,
        cosmosys_language: source.cosmosys_language,
        cslast_id: destination.issues.maximum(:csidnum).to_i
      )
      destination.cosmosys_enable_required_trackers!
    end

    def validate_native_copy!
      if context.copying?('issues') && context.issue_map.length != source.issues.count
        raise ProjectCopyError, "Only #{context.issue_map.length} of #{source.issues.count} items were copied"
      end
      if context.copying?('documents') && context.document_map.length != source.documents.count
        raise ProjectCopyError, "Only #{context.document_map.length} of #{source.documents.count} documents were copied"
      end
    end

    def apply_mode!
      return unless context.mode == 'clean'

      context.issue_map.each_value do |issue|
        issue.reload
        issue.status = issue.tracker.default_status
        issue.done_ratio = 0 if issue.respond_to?(:done_ratio=)
        issue.start_date = nil
        issue.due_date = nil
        issue.closed_on = nil if issue.respond_to?(:closed_on=)
        issue.save!
      end
    end

    def copy_document_references!
      return unless context.copying?('issues') && context.copying?('documents')

      @catalog_ref_map = {}
      Cosmosys::CatalogRef.joins(:document_catalog_entry)
                          .where(issue_id: context.issue_map.keys, cosmosys_document_catalog_entries: { project_id: source.id })
                          .ordered.each do |source_ref|
        issue = context.issue_map.fetch(source_ref.issue_id)
        document = context.document_map.fetch(source_ref.document_id)
        entry = Cosmosys::DocumentCatalogEntry.find_or_create_for!(document: document, family: source_ref.family)
        copy = Cosmosys::CatalogRef.create!(
          issue: issue,
          document_catalog_entry: entry,
          sense: source_ref.sense,
          location: source_ref.location
        )
        @catalog_ref_map[source_ref.id] = copy
      end
    end

    def remove_external_relations!
      copied_ids = context.issue_map.values.map(&:id).to_set
      removed = 0
      IssueRelation.where('issue_from_id IN (?) OR issue_to_id IN (?)', copied_ids, copied_ids).find_each do |relation|
        next if copied_ids.include?(relation.issue_from_id) && copied_ids.include?(relation.issue_to_id)
        relation.destroy!
        removed += 1
      end
      context.summary[:external_relations_omitted] = removed
    end

    def rewrite_internal_references!
      csid_map = context.issue_map.to_h { |source_id, copy| [Issue.where(id: source_id).pick(:csid), copy.csid] }.compact
      marker_map = (@catalog_ref_map || {}).to_h { |source_id, copy| ["document:di#{source_id}", copy.markdown_reference] }
      id_map = context.issue_map.to_h { |source_id, copy| ["##{source_id}", "##{copy.id}"] }
      replacements = csid_map.merge(marker_map).merge(id_map)

      context.issue_map.each_value do |issue|
        description = replace_tokens(issue.description.to_s, replacements)
        issue.update_columns(description: description, updated_on: Time.current) if description != issue.description.to_s
        issue.custom_field_values.each do |value|
          next unless value.custom_field.field_format.in?(%w[string text link])
          replaced = replace_tokens(value.value.to_s, replacements)
          next if replaced == value.value.to_s
          value.update_columns(value: replaced)
        end
      end
    end

    def replace_tokens(text, replacements)
      replacements.sort_by { |source, _target| -source.length }.reduce(text) do |result, (source, target)|
        result.gsub(/(?<![A-Za-z0-9_-])#{Regexp.escape(source)}(?![A-Za-z0-9_-])/, target)
      end
    end

    def copy_report_settings!
      return unless source.cosmosys_report_setting_record

      attributes = source.cosmosys_report_setting_record.attributes.except('id', 'project_id', 'created_at', 'updated_at')
      destination.create_cosmosys_report_setting_record!(attributes)
    end

    def summary
      {
        mode: context.mode,
        items: context.issue_map.length,
        documents: context.document_map.length,
        catalog_refs: (@catalog_ref_map || {}).length,
        members: destination.members.count
      }
    end
  end
end
