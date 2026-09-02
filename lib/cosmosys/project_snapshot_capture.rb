require 'digest'

module Cosmosys
  class ProjectSnapshotCapture
    SCHEMA_VERSION = '1'.freeze

    def initialize(project, user:, name: nil)
      @project = project
      @user = user
      @name = name.to_s.strip.presence
    end

    def call
      raise Unauthorized unless user && project.visible?(user)
      raise Unauthorized unless user.admin? || user.allowed_to?(:edit_project, project)

      content = capture_content
      canonical_content = CanonicalJson.generate(content)
      digest = Digest::SHA256.hexdigest(canonical_content)
      manifest = {
        'schema' => 'cosmosys-project-snapshot',
        'schema_version' => SCHEMA_VERSION,
        'content_sha256' => digest,
        'captured_at' => Time.current.utc.iso8601(6),
        'captured_by' => user.login,
        'content' => content
      }

      Cosmosys::ProjectSnapshot.create!(
        project: project,
        created_by: user,
        name: name,
        schema_version: SCHEMA_VERSION,
        content_sha256: digest,
        manifest_json: CanonicalJson.generate(manifest),
        item_count: content.fetch('items').length,
        document_count: content.fetch('documents').length,
        relation_count: content.fetch('relations').length
      )
    end

    private

    attr_reader :project, :user, :name

    def capture_content
      issues = project.issues.visible(user).includes(:tracker, :status, :priority, :author, :assigned_to,
                                                     :category, :fixed_version, :custom_values, :attachments)
                      .order(:csposition, :id).to_a
      issue_ids = issues.map(&:id).to_set
      documents = project.documents.visible(user).includes(:category, :attachments).order(:id).to_a
      document_ids = documents.map(&:id).to_set

      {
        'project' => project_payload,
        'items' => issues.map { |issue| issue_payload(issue, issue_ids) },
        'relations' => relation_payloads(issue_ids),
        'documents' => documents.map { |document| document_payload(document) },
        'document_catalog' => catalog_payloads(issue_ids, document_ids)
      }
    end

    def project_payload
      profile = Cosmosys::ProjectProfileRegistry.fetch(project.csys_project_profile)
      {
        'identifier' => project.identifier,
        'name' => project.name,
        'description' => project.description.to_s,
        'cscode' => project.cscode,
        'profile' => profile.key,
        'language' => project.cosmosys_effective_language,
        'report_code' => project.csys_report_code,
        'report_export_format' => project.cosmosys_effective_report_export_format,
        'enabled_modules' => project.enabled_module_names.map(&:to_s).sort,
        'trackers' => project.trackers.map { |tracker| tracker_identity(tracker) }.sort_by { |entry| entry['key'].to_s }
      }
    end

    def issue_payload(issue, issue_ids)
      visible_custom_values = if issue.respond_to?(:visible_custom_field_values)
                                issue.visible_custom_field_values(user)
                              else
                                issue.custom_field_values
                              end
      {
        'csid' => issue.csid,
        'csidnum' => issue.csidnum,
        'position' => issue.csposition,
        'parent_csid' => issue_ids.include?(issue.parent_id) ? issue.parent&.csid : nil,
        'tracker' => tracker_identity(issue.tracker),
        'subject' => issue.subject,
        'description' => issue.description.to_s,
        'status' => issue.status&.name,
        'priority' => issue.priority&.name,
        'author' => issue.author&.login,
        'assigned_to' => principal_identity(issue.assigned_to),
        'category' => issue.category&.name,
        'fixed_version' => issue.fixed_version&.name,
        'start_date' => issue.start_date,
        'due_date' => issue.due_date,
        'estimated_hours' => issue.estimated_hours,
        'done_ratio' => issue.done_ratio,
        'is_private' => issue.is_private,
        'closed_on' => issue.closed_on,
        'preferred_report_diagram' => issue.csys_preferred_report_diagram,
        'profile_fields' => Cosmosys::OdsItemFieldRegistry.values_for(issue),
        'custom_fields' => visible_custom_values.map { |value| custom_value_payload(value) }.sort_by { |entry| entry['id'] },
        'attachments' => attachment_payloads(issue.attachments)
      }
    end

    def relation_payloads(issue_ids)
      IssueRelation.where(issue_from_id: issue_ids).where(issue_to_id: issue_ids).order(:id).map do |relation|
        {
          'from' => relation.issue_from.csid,
          'to' => relation.issue_to.csid,
          'type' => relation.relation_type,
          'delay' => relation.delay,
          'restricted' => relation.csys_restricted
        }
      end
    end

    def document_payload(document)
      {
        'key' => "document:#{document.id}",
        'title' => document.title,
        'description' => document.description.to_s,
        'category' => document.category&.name,
        'external_code' => document.external_code,
        'date' => document.csys_document_date,
        'version' => document.csys_document_version,
        'attachments' => attachment_payloads(document.attachments)
      }
    end

    def catalog_payloads(issue_ids, document_ids)
      Cosmosys::DocumentCatalogEntry.where(project_id: project.id, document_id: document_ids)
                                    .includes(:catalog_refs).order(:family, :position, :id).map do |entry|
        {
          'document_key' => "document:#{entry.document_id}",
          'family' => entry.family,
          'position' => entry.position,
          'references' => entry.catalog_refs.select { |reference| issue_ids.include?(reference.issue_id) }
                               .sort_by(&:id).map do |reference|
            { 'item' => reference.issue.csid, 'sense' => reference.sense, 'location' => reference.location }
          end
        }
      end
    end

    def custom_value_payload(value)
      field = value.custom_field
      { 'id' => field.id, 'name' => field.name, 'format' => field.field_format, 'value' => value.value }
    end

    def attachment_payloads(attachments)
      attachments.sort_by(&:id).map do |attachment|
        {
          'filename' => attachment.filename,
          'content_type' => attachment.content_type,
          'byte_size' => attachment.filesize,
          'content_sha256' => attachment_sha256(attachment)
        }
      end
    end

    def attachment_sha256(attachment)
      path = attachment.diskfile.to_s
      raise ActiveRecord::RecordNotFound, "Attachment payload is unavailable: #{attachment.filename}" unless File.file?(path)

      Digest::SHA256.file(path).hexdigest
    end

    def tracker_identity(tracker)
      { 'key' => tracker&.csys_key.presence || tracker&.name, 'name' => tracker&.name, 'item_profile' => tracker&.csys_item_kind }
    end

    def principal_identity(principal)
      return nil unless principal
      principal.respond_to?(:login) ? principal.login : principal.name
    end
  end
end
