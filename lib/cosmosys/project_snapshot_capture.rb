require 'digest'
require 'stringio'
require 'zlib'

module Cosmosys
  class ProjectSnapshotCapture
    SCHEMA_VERSION = '3'.freeze

    def initialize(project, user:, name: nil, projects: nil)
      @project = project
      @user = user
      @name = name.to_s.strip.presence
      selected_ids = projects.nil? ? [project.id] : projects
      @projects = ProjectSnapshotSelection.new(project, user: user).resolve(selected_ids)
    end

    def call
      payload = manifest
      digest = payload.fetch('content_sha256')

      Cosmosys::ProjectSnapshot.transaction do
        snapshot = Cosmosys::ProjectSnapshot.create!(
          project: project,
          created_by: user,
          name: name,
          schema_version: SCHEMA_VERSION,
          content_sha256: digest,
          manifest_gzip: gzip(CanonicalJson.generate(payload)),
          item_count: project_entries.sum { |entry| entry.fetch('items').length },
          document_count: project_entries.sum { |entry| entry.fetch('documents').length },
          relation_count: payload.fetch('content').fetch('relations').length
        )
        retain_attachment_payloads!(snapshot)
        # Attachment creation happens after the snapshot has been persisted.  A
        # validation or callback may already have loaded the association, so
        # return a fresh instance rather than exposing a stale empty cache.
        snapshot.reload
      end
    end

    # A live copy uses the exact same immutable representation as a retained
    # snapshot, but does not need to create a snapshot database record.
    def manifest
      @manifest ||= begin
        content = capture_content
        digest = Digest::SHA256.hexdigest(CanonicalJson.generate(content))
        {
          'schema' => 'cosmosys-project-snapshot',
          'schema_version' => SCHEMA_VERSION,
          'content_sha256' => digest,
          'captured_at' => Time.current.utc.iso8601(6),
          'captured_by' => user.login,
          'content' => content
        }
      end
    end

    def asset_path(digest)
      attachment = Array(@source_attachments).find { |candidate| attachment_sha256(candidate) == digest }
      raise ActiveRecord::RecordNotFound, "Snapshot asset is unavailable: #{digest}" unless attachment

      attachment.diskfile
    end

    private

    attr_reader :project, :projects, :user, :name

    def capture_content
      @project_entries = projects.map { |selected| capture_project(selected) }
      issues = @project_entries.flat_map { |entry| entry.delete('_issues') }
      issue_ids = issues.map(&:id).to_set
      issues_by_id = issues.index_by(&:id)
      @project_entries.each do |entry|
        entry.fetch('items').each do |row|
          parent_id = issues_by_id.fetch(row.fetch('source_id')).parent_id
          row['parent_key'] = "item:#{parent_id}" if issue_ids.include?(parent_id)
        end
      end
      root = project.root || project

      {
        'root' => { 'source_id' => root.id, 'identifier' => root.identifier },
        'primary_project_source_id' => project.id,
        'platform' => {
          'redmine_version' => Redmine::VERSION.to_s,
          'plugins' => Redmine::Plugin.all.map { |plugin| plugin_payload(plugin) }
                                    .sort_by { |entry| entry.fetch('id') }
        },
        'projects' => @project_entries,
        'relations' => relation_payloads(issue_ids),
        'external_relations' => external_relation_payloads(issue_ids)
      }
    end

    def plugin_payload(plugin)
      { 'id' => plugin.id.to_s, 'name' => plugin.name.to_s, 'version' => plugin.version.to_s }
    end

    def capture_project(selected)
      issues = selected.issues.visible(user).includes(:tracker, :status, :priority, :author, :assigned_to,
                                                      :category, :fixed_version, :custom_values, :attachments,
                                                      :cosmosys_presentation_baselines)
                       .order(:csposition, :id).to_a
      issue_ids = issues.map(&:id).to_set
      documents = selected.documents.visible(user).includes(:category, :attachments).order(:id).to_a
      document_ids = documents.map(&:id).to_set
      @source_attachments ||= []
      @source_attachments.concat(issues.flat_map { |issue| issue.attachments.to_a })
      @source_attachments.concat(documents.flat_map { |document| document.attachments.to_a })

      {
        'key' => "project:#{selected.id}",
        'source_id' => selected.id,
        'parent_key' => projects.include?(selected.parent) ? "project:#{selected.parent_id}" : nil,
        'project' => project_payload(selected),
        'items' => issues.map { |issue| issue_payload(issue, issue_ids) },
        'documents' => documents.map { |document| document_payload(document) },
        'document_catalog' => catalog_payloads(selected, issue_ids, document_ids),
        '_issues' => issues
      }
    end

    def project_entries
      @project_entries || []
    end

    def project_payload(selected)
      profile = Cosmosys::ProjectProfileRegistry.fetch(selected.csys_project_profile)
      {
        'identifier' => selected.identifier, 'name' => selected.name,
        'description' => selected.description.to_s, 'cscode' => selected.cscode,
        'profile' => profile.key, 'language' => selected.cosmosys_effective_language,
        'report_code' => selected.csys_report_code,
        'wp' => selected.csys_wp,
        'wp_title' => selected.csys_wp_title,
        'report_export_format' => selected.cosmosys_effective_report_export_format,
        'enabled_modules' => selected.enabled_module_names.map(&:to_s).sort,
        'trackers' => selected.trackers.map { |tracker| tracker_identity(tracker) }.sort_by { |entry| entry['key'].to_s }
      }
    end

    def issue_payload(issue, issue_ids)
      visible_custom_values = if issue.respond_to?(:visible_custom_field_values)
                                issue.visible_custom_field_values(user)
                              else
                                issue.custom_field_values
                              end
      {
        'key' => "item:#{issue.id}", 'source_id' => issue.id,
        'csid' => issue.csid,
        'csidnum' => issue.csidnum,
        'position' => issue.csposition,
        'parent_key' => issue_ids.include?(issue.parent_id) ? "item:#{issue.parent_id}" : nil,
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
        'presentation_baselines' => issue.cosmosys_presentation_baselines.order(:attribute_name).map do |baseline|
          {
            'attribute' => baseline.attribute_name,
            'source_text' => baseline.source_text,
            'resolved_text' => baseline.resolved_text,
            'ledger' => baseline.ledger,
            'resolved_sha256' => baseline.resolved_sha256,
            'captured_status' => baseline.captured_status&.name,
            'captured_maturity' => baseline.captured_maturity || baseline.captured_status&.cosmosys_maturity_level.to_i,
            'captured_at' => baseline.captured_at&.utc&.iso8601(6)
          }
        end,
        'profile_fields' => Cosmosys::OdsItemFieldRegistry.values_for(issue),
        'custom_fields' => visible_custom_values.map { |value| custom_value_payload(value) }.sort_by { |entry| entry['id'] },
        'attachments' => attachment_payloads(issue.attachments)
      }
    end

    def relation_payloads(issue_ids)
      IssueRelation.where(issue_from_id: issue_ids).where(issue_to_id: issue_ids).order(:id).map do |relation|
        {
          'from' => "item:#{relation.issue_from_id}",
          'to' => "item:#{relation.issue_to_id}",
          'type' => relation.relation_type,
          'delay' => relation.delay,
          'restricted' => relation.csys_restricted
        }
      end
    end

    def external_relation_payloads(issue_ids)
      visible_ids = Issue.visible(user).where(id: IssueRelation.where(issue_from_id: issue_ids).or(IssueRelation.where(issue_to_id: issue_ids)).pluck(:issue_from_id, :issue_to_id).flatten.uniq).pluck(:id).to_set
      IssueRelation.where(issue_from_id: issue_ids).or(IssueRelation.where(issue_to_id: issue_ids)).order(:id).filter_map do |relation|
        from_inside = issue_ids.include?(relation.issue_from_id)
        to_inside = issue_ids.include?(relation.issue_to_id)
        next if from_inside == to_inside
        external_id = from_inside ? relation.issue_to_id : relation.issue_from_id
        next unless visible_ids.include?(external_id)

        external = Issue.find(external_id)
        {
          'local' => "item:#{from_inside ? relation.issue_from_id : relation.issue_to_id}",
          'local_side' => from_inside ? 'from' : 'to',
          'external_csid' => external.csid,
          'external_project_identifier' => external.project.identifier,
          'type' => relation.relation_type, 'delay' => relation.delay,
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

    def catalog_payloads(selected, issue_ids, document_ids)
      Cosmosys::DocumentCatalogEntry.where(project_id: selected.id, document_id: document_ids)
                                    .includes(:catalog_refs).order(:family, :position, :id).map do |entry|
        {
          'document_key' => "document:#{entry.document_id}",
          'family' => entry.family,
          'position' => entry.position,
          'references' => entry.catalog_refs.select { |reference| issue_ids.include?(reference.issue_id) }
                               .sort_by(&:id).map do |reference|
            { 'key' => "document:di#{reference.id}", 'item' => "item:#{reference.issue_id}",
              'sense' => reference.sense, 'location' => reference.location }
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

    def retain_attachment_payloads!(snapshot)
      Array(@source_attachments).uniq(&:id).group_by { |attachment| attachment_sha256(attachment) }.each do |digest, matches|
        source = matches.first
        File.open(source.diskfile, 'rb') do |file|
          Attachment.create!(
            container: snapshot,
            author: user,
            file: file,
            filename: "#{digest}.csys-asset",
            content_type: 'application/octet-stream',
            description: "cosmoSys snapshot asset #{digest}"
          )
        end
      end
    end

    def gzip(content)
      output = StringIO.new
      writer = Zlib::GzipWriter.new(output)
      writer.mtime = 0
      writer.write(content)
      writer.close
      output.string
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
