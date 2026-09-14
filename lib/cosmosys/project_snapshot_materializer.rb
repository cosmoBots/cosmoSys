require 'set'

module Cosmosys
  class ProjectSnapshotMaterializer
    def initialize(source, user:, attributes:)
      @source = source
      @user = user
      @attributes = attributes.to_h.stringify_keys
    end

    def call
      raise Unauthorized unless user&.admin?
      projects = materialize_projects!
      projects.fetch(plan.destination_projects.find { |entry| entry[:parent_key].blank? }.fetch(:key))
    end

    # Shared batch writer for an authorized live tree copy. The optional block
    # runs after every project shell exists but before snapshot content is
    # written, allowing Redmine to copy its native project-owned entities.
    def materialize_projects!(selected_parts: nil)
      @plan = preflight!

      ActiveRecord::Base.transaction do
        content = source.manifest.fetch('content')
        entries = content.fetch('projects')
        projects = create_projects!(entries)
        yield projects if block_given?
        materialize_contents!(
          content, entries, projects,
          selected_parts: selected_parts && Array(selected_parts).map(&:to_s)
        )
        projects
      end
    end

    # Populate a project which Redmine has already created while copying its
    # native parts (members, wiki, queries, boards...). This is the shared
    # entity writer used by live copy and retained/portable snapshots.
    def materialize_into!(project, selected_parts:, copy_context: nil)
      content = source.manifest.fetch('content')
      entries = content.fetch('projects')
      raise ProjectCopyError, I18n.t(:error_cosmosys_snapshot_ambiguous_roots) unless entries.one?

      materialize_contents!(
        content,
        entries,
        { entries.first.fetch('key') => project },
        selected_parts: Array(selected_parts).map(&:to_s),
        copy_context: copy_context
      )
      project
    end

    private

    attr_reader :source, :user, :attributes

    def plan
      @plan
    end

    def preflight!
      plan = ProjectSnapshotMaterializationPlan.new(source: source, attributes: attributes)
      return plan if plan.blocking_messages.empty?

      raise ProjectCopyError, plan.blocking_messages.join(' ')
    end

    def create_projects!(entries)
      destination_rows = plan.destination_projects.index_by { |row| row.fetch(:key) }
      pending = entries.dup
      projects = {}
      until pending.empty?
        ready, pending = pending.partition do |entry|
          entry['parent_key'].blank? || projects.key?(entry['parent_key'])
        end
        raise ProjectCopyError, I18n.t(:error_cosmosys_snapshot_ambiguous_roots) if ready.empty?

        ready.each do |entry|
          destination = destination_rows.fetch(entry.fetch('key'))
          parent = entry['parent_key'].present? ? projects.fetch(entry['parent_key']) : destination_parent
          projects[entry.fetch('key')] = create_project!(destination, parent)
        end
      end
      projects
    end

    def materialize_contents!(content, entries, projects, selected_parts: nil, copy_context: nil)
      @reused_item_keys = Set.new
      include_items = selected_parts.nil? || selected_parts.include?('issues')
      include_documents = selected_parts.nil? || selected_parts.include?('documents')
      items = {}
      if include_items
        items = entries.each_with_object({}) do |entry, map|
          map.merge!(create_items!(projects.fetch(entry.fetch('key')), entry.fetch('items')))
        end
        entries.each do |entry|
          apply_identity_policy!(projects.fetch(entry.fetch('key')), items, entry.fetch('items'))
        end
        rows = entries.flat_map { |entry| entry.fetch('items') }
        apply_deferred_profile_fields!(items, rows)
        restore_hierarchy!(items, rows)
        restore_relations!(items, content.fetch('relations'))
      end

      documents = {}
      if include_documents
        documents = entries.each_with_object({}) do |entry, map|
          map.merge!(create_documents!(projects.fetch(entry.fetch('key')), entry.fetch('documents')))
        end
      end

      marker_map = {}
      if include_items && include_documents
        entries.each do |entry|
          marker_map.merge!(restore_catalog!(projects.fetch(entry.fetch('key')), items, documents,
                                             entry.fetch('document_catalog')))
        end
      end
      rewrite_internal_references!(items, entries.flat_map { |entry| entry.fetch('items') }, marker_map) if include_items
      register_copy_maps!(copy_context, items, documents)
      copy_context.summary[:catalog_refs] = marker_map.length if copy_context
    end

    def create_project!(destination, parent)
      source = destination.fetch(:source)
      project = Project.create!(
        name: destination.fetch(:name),
        identifier: destination.fetch(:identifier),
        cscode: destination.fetch(:cscode),
        description: source['description'].to_s,
        parent: parent,
        is_public: false,
        csys_project_profile: source.fetch('profile'),
        csys_language: source['language'],
        csys_report_code: source['report_code'],
        csys_report_export_format: source['report_export_format']
      )
      tracker_keys = source.fetch('trackers').map { |entry| entry['key'] }
      project.trackers = Tracker.where(csys_key: tracker_keys).or(Tracker.where(name: tracker_keys)).to_a
      project.enabled_module_names = source.fetch('enabled_modules')
      project.save!
      project
    end

    def destination_parent
      @destination_parent ||= attributes['parent_id'].present? ? Project.find(attributes['parent_id']) : nil
    end

    def create_items!(project, rows)
      rows.to_h do |row|
        tracker_key = row.dig('tracker', 'key')
        tracker = Tracker.find_by(csys_key: tracker_key) || Tracker.find_by(name: tracker_key) ||
                  raise(ActiveRecord::RecordNotFound, "Tracker #{tracker_key} is unavailable")
        semantic_identity = tracker.cosmosys_item_kind_profile.user_defined_csid == true
        if semantic_identity && tracker.cosmosys_item_kind_profile.defines_project_data == true
          existing = reconcile_project_data!(project, row)
          if existing
            @reused_item_keys.add(row.fetch('key'))
            next [row.fetch('key'), existing]
          end
        end
        identity = (identity_mode == 'preserve' || semantic_identity) ? {
          csid: row.fetch('csid'), csidnum: row.fetch('csidnum'), csposition: row.fetch('position')
        } : {}
        issue = Issue.new({
          project: project,
          tracker: tracker,
          status: item_status(tracker, row),
          priority: IssuePriority.find_by(name: row['priority']) || IssuePriority.default,
          author: User.find_by(login: row['author']) || user,
          assigned_to: principal(row['assigned_to']),
          subject: row.fetch('subject'),
          description: row['description'].to_s,
          start_date: faithful? ? row['start_date'] : nil,
          due_date: faithful? ? row['due_date'] : nil,
          estimated_hours: row['estimated_hours'], done_ratio: faithful? ? row['done_ratio'] : 0,
          is_private: row['is_private'], csys_preferred_report_diagram: row['preferred_report_diagram']
        }.merge(identity))
        issue.category = project.issue_categories.find_or_create_by!(name: row['category']) if row['category'].present?
        issue.fixed_version = project.versions.find_or_create_by!(name: row['fixed_version']) if row['fixed_version'].present?
        Cosmosys::OdsItemFieldRegistry.apply(issue, row.fetch('profile_fields', {}), phase: :immediate)
        assign_custom_fields!(issue, project, row.fetch('custom_fields', []))
        issue.save!
        restore_attachments!(issue, row.fetch('attachments'))
        [row.fetch('key'), issue]
      end
    end

    def item_status(tracker, row)
      return tracker.default_status unless faithful?

      IssueStatus.find_by(name: row['status']) || IssueStatus.sorted.first
    end

    def apply_deferred_profile_fields!(items, rows)
      csid_map = rows.to_h { |row| [row.fetch('csid'), items.fetch(row.fetch('key')).csid] }
      rows.each do |row|
        next if @reused_item_keys.include?(row.fetch('key'))

        issue = items.fetch(row.fetch('key')).reload
        Cosmosys::OdsItemFieldRegistry.apply(
          issue, row.fetch('profile_fields', {}), phase: :deferred, context: { csid_map: csid_map }
        )
        issue.save! if issue.changed?
      end
    end

    def apply_identity_policy!(project, items, rows)
      entries = rows.reject { |row| @reused_item_keys.include?(row.fetch('key')) }.map do |row|
        { issue: items.fetch(row.fetch('key')), csid: row.fetch('csid'),
          csidnum: row.fetch('csidnum'), position: row.fetch('position') }
      end
      ProjectMaterializationIdentity.new(
        mode: identity_mode,
        destination: project,
        entries: entries
      ).apply!
    end

    def restore_hierarchy!(items, rows)
      rows.each do |row|
        next if @reused_item_keys.include?(row.fetch('key'))

        parent = items[row['parent_key']]
        # Redmine's nested-set maintenance can advance siblings' lock_version
        # while preceding parents are restored.  Always update a fresh object.
        items.fetch(row.fetch('key')).reload.update!(parent_issue_id: parent.id) if parent
      end
    end

    def reconcile_project_data!(project, row)
      root = project.root || project
      profile_keys = ItemKindRegistry.all.select(&:defines_project_data).map(&:key)
      existing = Issue.joins(:tracker)
                      .where(project_id: root.self_and_descendants.select(:id), trackers: { csys_item_kind: profile_keys })
                      .where('LOWER(issues.csid) = ?', row.fetch('csid').downcase)
                      .first
      return unless existing

      source_name = row.fetch('subject').to_s
      source_value = row.fetch('profile_fields', {})['csys_value'].to_s
      return existing if existing.subject.to_s == source_name && existing.csys_value.to_s == source_value

      case project_data_conflict_policy
      when 'keep'
        existing
      when 'overwrite'
        unless existing.editable?(user)
          raise ProjectCopyError, I18n.t(:error_cosmosys_project_data_overwrite_forbidden, key: row.fetch('csid'))
        end
        existing.update!(subject: source_name, csys_value: source_value)
        existing
      else
        raise ProjectCopyError, I18n.t(:error_cosmosys_project_data_conflicts, keys: row.fetch('csid'))
      end
    end

    def assign_custom_fields!(issue, project, rows)
      values = rows.to_h do |entry|
        field = IssueCustomField.find_by(id: entry['id'], name: entry.fetch('name')) ||
                IssueCustomField.find_by(name: entry.fetch('name'), field_format: entry.fetch('format'))
        unless field
          raise ProjectSnapshotPackageError,
                I18n.t(:error_cosmosys_snapshot_custom_field_missing, field: entry.fetch('name'))
        end
        project.issue_custom_fields << field unless project.all_issue_custom_fields.include?(field)
        [field.id.to_s, entry['value']]
      end
      issue.custom_field_values = values
    end

    def restore_relations!(items, rows)
      rows.each do |row|
        IssueRelation.create!(issue_from: items.fetch(row.fetch('from')), issue_to: items.fetch(row.fetch('to')),
                              relation_type: row.fetch('type'), delay: row['delay'], csys_restricted: row['restricted'])
      end
    end

    def create_documents!(project, rows)
      rows.to_h do |row|
        category = DocumentCategory.find_or_create_by!(name: row['category'].presence || 'Documentation')
        document = Document.create!(project: project, category: category, title: row.fetch('title'),
                                    description: row['description'].to_s, external_code: row['external_code'],
                                    csys_document_date: row['date'], csys_document_version: row['version'])
        restore_attachments!(document, row.fetch('attachments'))
        [row.fetch('key'), document]
      end
    end

    def restore_catalog!(project, items, documents, rows)
      marker_map = {}
      rows.each do |row|
        entry = Cosmosys::DocumentCatalogEntry.create!(project: project, document: documents.fetch(row.fetch('document_key')),
                                                        family: row.fetch('family'), position: row.fetch('position'))
        row.fetch('references').each do |reference|
          copy = entry.catalog_refs.create!(issue: items.fetch(reference.fetch('item')), sense: reference.fetch('sense'), location: reference['location'])
          marker_map[reference.fetch('key')] = copy.markdown_reference
        end
      end
      marker_map
    end

    def rewrite_internal_references!(items, rows, marker_map)
      csid_map = rows.to_h { |row| [row.fetch('csid'), items.fetch(row.fetch('key')).csid] }
      id_map = rows.to_h { |row| ["##{row.fetch('source_id')}", "##{items.fetch(row.fetch('key')).id}"] }
      MaterializationReferenceRewriter.new(
        issues: items.values, csid_map: csid_map, id_map: id_map,
        marker_map: marker_map
      ).call
    end

    def restore_attachments!(container, rows)
      rows.each do |row|
        File.open(asset_path(row.fetch('content_sha256')), 'rb') do |file|
          Attachment.create!(container: container, author: user, file: file, filename: row.fetch('filename'),
                             content_type: row['content_type'], description: row['description'])
        end
      end
    end

    def asset_path(digest)
      return source.asset_path(digest) if source.respond_to?(:asset_path)

      source.attachments.find_by!(digest: digest).diskfile
    end

    def identity_mode
      ProjectCopyContext::IDENTITY_MODES.include?(attributes['identity_mode'].to_s) ? attributes['identity_mode'].to_s : 'preserve'
    end

    def project_data_conflict_policy
      ProjectDataReconciliation::POLICIES.include?(attributes['project_data_conflict_policy'].to_s) ?
        attributes['project_data_conflict_policy'].to_s : 'cancel'
    end

    def faithful?
      attributes['copy_mode'].to_s != 'clean'
    end

    def register_copy_maps!(context, items, documents)
      return unless context

      items.each do |key, issue|
        context.register_issue(key.delete_prefix('item:').to_i, issue)
      end
      documents.each do |key, document|
        context.register_document(key.delete_prefix('document:').to_i, document)
      end
    end

    def principal(identity)
      return nil if identity.blank?
      User.find_by(login: identity) || Group.find_by(lastname: identity)
    end
  end
end
