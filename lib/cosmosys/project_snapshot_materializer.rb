module Cosmosys
  class ProjectSnapshotMaterializer
    def initialize(source, user:, attributes:)
      @source = source
      @user = user
      @attributes = attributes.to_h.stringify_keys
    end

    def call
      raise Unauthorized unless user&.admin?
      preflight!

      ActiveRecord::Base.transaction do
        content = source.manifest.fetch('content')
        project = create_project!(content.fetch('project'))
        items = create_items!(project, content.fetch('items'))
        apply_identity_policy!(project, items, content.fetch('items'))
        restore_hierarchy!(items, content.fetch('items'))
        restore_relations!(items, content.fetch('relations'))
        documents = create_documents!(project, content.fetch('documents'))
        marker_map = restore_catalog!(project, items, documents, content.fetch('document_catalog'))
        rewrite_internal_references!(items, content.fetch('items'), marker_map)
        project
      end
    end

    private

    attr_reader :source, :user, :attributes

    def preflight!
      manifest = source.manifest
      unless manifest['schema'] == 'cosmosys-project-snapshot' &&
             manifest['schema_version'].to_s == ProjectSnapshotCapture::SCHEMA_VERSION
        raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_schema)
      end
      content = manifest.fetch('content')
      project = content.fetch('project')
      profile = project.fetch('profile')
      raise ProjectCopyError, "Unknown project profile #{profile}" unless ProjectProfileRegistry.registered?(profile)
      raise ProjectCopyError, I18n.t(:error_cosmosys_snapshot_identifier_taken) if Project.exists?(identifier: attributes.fetch('identifier'))

      return unless identity_mode == 'preserve'
      parent = attributes['parent_id'].present? ? Project.find(attributes['parent_id']) : nil
      return unless parent

      project_ids = parent.root.self_and_descendants.pluck(:id)
      csids = content.fetch('items').map { |row| row.fetch('csid').downcase }
      collisions = Issue.where(project_id: project_ids).where('LOWER(csid) IN (?)', csids).pluck(:csid)
      return if collisions.empty?

      raise ProjectCopyError,
            I18n.t(:error_cosmosys_preserve_csid_collision, csids: collisions.sort.join(', '))
    end

    def create_project!(source)
      parent = attributes['parent_id'].present? ? Project.find(attributes['parent_id']) : nil
      project = Project.create!(
        name: attributes.fetch('name'),
        identifier: attributes.fetch('identifier'),
        cscode: destination_cscode(source),
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

    def create_items!(project, rows)
      rows.to_h do |row|
        tracker_key = row.dig('tracker', 'key')
        tracker = Tracker.find_by(csys_key: tracker_key) || Tracker.find_by(name: tracker_key) ||
                  raise(ActiveRecord::RecordNotFound, "Tracker #{tracker_key} is unavailable")
        identity = identity_mode == 'preserve' ? {
          csid: row.fetch('csid'), csidnum: row.fetch('csidnum'), csposition: row.fetch('position')
        } : {}
        issue = Issue.new({
          project: project,
          tracker: tracker,
          status: IssueStatus.find_by(name: row['status']) || IssueStatus.sorted.first,
          priority: IssuePriority.find_by(name: row['priority']) || IssuePriority.default,
          author: User.find_by(login: row['author']) || user,
          assigned_to: principal(row['assigned_to']),
          subject: row.fetch('subject'),
          description: row['description'].to_s,
          start_date: row['start_date'], due_date: row['due_date'],
          estimated_hours: row['estimated_hours'], done_ratio: row['done_ratio'],
          is_private: row['is_private'], csys_preferred_report_diagram: row['preferred_report_diagram']
        }.merge(identity))
        issue.category = project.issue_categories.find_or_create_by!(name: row['category']) if row['category'].present?
        issue.fixed_version = project.versions.find_or_create_by!(name: row['fixed_version']) if row['fixed_version'].present?
        Cosmosys::OdsItemFieldRegistry.apply(issue, row.fetch('profile_fields', {}))
        assign_custom_fields!(issue, project, row.fetch('custom_fields', []))
        issue.save!
        restore_attachments!(issue, row.fetch('attachments'))
        [row.fetch('csid'), issue]
      end
    end

    def apply_identity_policy!(project, items, rows)
      entries = rows.map do |row|
        { issue: items.fetch(row.fetch('csid')), csid: row.fetch('csid'),
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
        parent = items[row['parent_csid']]
        # Redmine's nested-set maintenance can advance siblings' lock_version
        # while preceding parents are restored.  Always update a fresh object.
        items.fetch(row.fetch('csid')).reload.update!(parent_issue_id: parent.id) if parent
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
      csid_map = rows.to_h { |row| [row.fetch('csid'), items.fetch(row.fetch('csid')).csid] }
      id_map = rows.to_h { |row| ["##{row.fetch('source_id')}", "##{items.fetch(row.fetch('csid')).id}"] }
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

    def destination_cscode(source_project)
      attributes['cscode'].presence || source_project.fetch('cscode')
    end

    def principal(identity)
      return nil if identity.blank?
      User.find_by(login: identity) || Group.find_by(lastname: identity)
    end
  end
end
