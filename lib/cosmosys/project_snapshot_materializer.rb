module Cosmosys
  class ProjectSnapshotMaterializer
    def initialize(snapshot, user:, attributes:)
      @snapshot = snapshot
      @user = user
      @attributes = attributes.to_h.stringify_keys
    end

    def call
      raise Unauthorized unless user&.admin?

      ActiveRecord::Base.transaction do
        content = snapshot.manifest.fetch('content')
        project = create_project!(content.fetch('project'))
        items = create_items!(project, content.fetch('items'))
        restore_hierarchy!(items, content.fetch('items'))
        restore_relations!(items, content.fetch('relations'))
        documents = create_documents!(project, content.fetch('documents'))
        restore_catalog!(project, items, documents, content.fetch('document_catalog'))
        project
      end
    end

    private

    attr_reader :snapshot, :user, :attributes

    def create_project!(source)
      parent = attributes['parent_id'].present? ? Project.find(attributes['parent_id']) : nil
      project = Project.create!(
        name: attributes.fetch('name'),
        identifier: attributes.fetch('identifier'),
        cscode: attributes['cscode'].presence || source.fetch('cscode'),
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
        issue = Issue.new(
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
          is_private: row['is_private'], csys_preferred_report_diagram: row['preferred_report_diagram'],
          csid: row.fetch('csid'), csidnum: row.fetch('csidnum'), csposition: row.fetch('position')
        )
        issue.category = project.issue_categories.find_or_create_by!(name: row['category']) if row['category'].present?
        issue.fixed_version = project.versions.find_or_create_by!(name: row['fixed_version']) if row['fixed_version'].present?
        Cosmosys::OdsItemFieldRegistry.apply(issue, row.fetch('profile_fields', {}))
        issue.custom_field_values = row.fetch('custom_fields', {}).to_h { |entry| [entry.fetch('id').to_s, entry['value']] }
        issue.save!
        restore_attachments!(issue, row.fetch('attachments'))
        [row.fetch('csid'), issue]
      end.tap { project.update!(cslast_id: rows.map { |row| row.fetch('csidnum').to_i }.max.to_i) }
    end

    def restore_hierarchy!(items, rows)
      rows.each do |row|
        parent = items[row['parent_csid']]
        # Redmine's nested-set maintenance can advance siblings' lock_version
        # while preceding parents are restored.  Always update a fresh object.
        items.fetch(row.fetch('csid')).reload.update!(parent_issue_id: parent.id) if parent
      end
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
      rows.each do |row|
        entry = Cosmosys::DocumentCatalogEntry.create!(project: project, document: documents.fetch(row.fetch('document_key')),
                                                        family: row.fetch('family'), position: row.fetch('position'))
        row.fetch('references').each do |reference|
          entry.catalog_refs.create!(issue: items.fetch(reference.fetch('item')), sense: reference.fetch('sense'), location: reference['location'])
        end
      end
    end

    def restore_attachments!(container, rows)
      rows.each do |row|
        source = snapshot.attachments.find_by!(digest: row.fetch('content_sha256'))
        File.open(source.diskfile, 'rb') do |file|
          Attachment.create!(container: container, author: user, file: file, filename: row.fetch('filename'),
                             content_type: row['content_type'], description: row['description'])
        end
      end
    end

    def principal(identity)
      return nil if identity.blank?
      User.find_by(login: identity) || Group.find_by(lastname: identity)
    end
  end
end
