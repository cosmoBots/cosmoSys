require 'set'

module Cosmosys
  class OdsProjectMaterializer < OdsImportService
    attr_reader :destination_attributes, :mode, :profile_key, :destination

    def initialize(transfer, user:, destination_attributes: nil, mode: nil, profile_key: nil)
      super(transfer, user: user)
      saved = transfer.summary.fetch('materialization', {})
      @destination_attributes = (destination_attributes || saved.fetch('destination', {})).stringify_keys
      @mode = ProjectCopyContext::MODES.include?(mode.to_s) ? mode.to_s : saved.fetch('mode', 'clean')
      @profile_key = ProjectProfileRegistry.normalize_key(profile_key || saved['profile_key'])
    end

    def analyse!
      transfer.events.delete_all
      data = send(:read_workbook)
      manifest = data.fetch('manifest')
      error!('unsupported_format', "Unsupported ODS format #{manifest['format_version'].inspect}") unless manifest['format_version'] == FORMAT_VERSION
      error!('missing_export_id', 'Workbook has no export lineage') if manifest['export_id'].blank?
      error!('project_tree_not_supported', 'Project-tree snapshots cannot yet be materialised as one project') if manifest['include_subprojects'].to_s == '1'
      error!('unknown_project_profile', "Unknown project profile #{profile_key}") unless ProjectProfileRegistry.registered?(profile_key)
      validate_destination!
      validate_source_rows!(data)
      digest = send(:semantic_digest, data)
      details = {'destination' => destination_attributes, 'mode' => mode, 'profile_key' => profile_key,
                 'source_project' => manifest['project_identifier'], 'items' => data.fetch('items').length,
                 'documents' => data.fetch('documents').length, 'catalog_refs' => data.fetch('catalog').length,
                 'attachments_omitted' => true}
      blocking = transfer.events.where(severity: 'error').exists?
      transfer.summary = {'materialization' => details, 'blocking' => blocking, 'payload_sha256' => digest}
      transfer.assign_attributes(payload_sha256: digest, export_id: manifest['export_id'], format_version: manifest['format_version'],
                                 state: blocking ? 'rejected' : 'awaiting_confirmation')
      transfer.save!
      transfer
    rescue StandardError => error
      error!('analysis_failed', error.message)
      transfer.update!(state: 'failed', summary: {'blocking' => true, 'exception' => error.class.name})
      transfer
    end

    def apply!
      raise ImportError, 'Snapshot is not awaiting confirmation' unless transfer.applicable?
      raise ImportError, 'Only an administrator can materialise project snapshots' unless user.admin?
      data = send(:read_workbook)
      raise ImportError, 'Uploaded workbook changed after analysis' unless send(:semantic_digest, data) == transfer.payload_sha256

      transfer.update!(state: 'applying')
      items, documents, provisional = {}, {}, {}
      result = {'created_items' => 0, 'created_documents' => 0, 'created_catalog_refs' => 0,
                'updated_items' => 0, 'updated_documents' => 0, 'updated_catalog_refs' => 0}
      ActiveRecord::Base.transaction do
        @destination = create_destination!(data)
        prepare_rows!(data)
        send(:apply_items!, data.fetch('items'), data.fetch('extra'), items, result)
        apply_snapshot_hierarchy_and_relations!(data.fetch('items'), items)
        send(:apply_documents!, data.fetch('documents'), documents, result)
        send(:apply_catalog!, data.fetch('catalog'), items, documents, provisional, result)
        rewrite_snapshot_references!(data, items)
        destination.archive! if mode == 'faithful' && ActiveModel::Type::Boolean.new.cast(destination_attributes['archive'])
      end
      transfer.summary = transfer.summary.merge(result).merge('destination_project_id' => destination.id)
      transfer.update!(state: 'applied')
      transfer
    rescue StandardError => error
      error!('application_failed', error.message)
      transfer.update!(state: 'failed', summary: transfer.summary.merge('application_exception' => error.class.name))
      transfer
    end

    private

    def project = destination || transfer.project
    def resolve_item(_row) = nil
    def resolve_item_by_key(_key) = nil
    def resolve_document(_row) = nil
    def resolve_document_by_key(_key) = nil
    def resolve_catalog_ref(_row) = nil
    def row_project(_row) = destination

    def validate_destination!
      %w[name identifier cscode].each { |field| error!('missing_destination_field', "Destination #{field} is required") if destination_attributes[field].blank? }
      error!('identifier_taken', 'Destination identifier is already in use') if Project.exists?(identifier: destination_attributes['identifier'])
    end

    def validate_source_rows!(data)
      trackers = data.fetch('items').map { |row| row['tracker'] }.reject(&:blank?).uniq
      (trackers - Tracker.where(name: trackers).pluck(:name)).each { |name| error!('unknown_tracker', "Unknown tracker #{name}") }
      send(:validate_duplicate_rows!, data)
      item_keys = data.fetch('items').map { |row| row['csid'] }.to_set
      document_keys = data.fetch('documents').flat_map { |row| [row['source_id'], row['redmine_id']] }.reject(&:blank?).to_set
      data.fetch('items').each do |row|
        warning!('external_parent_omitted', "Parent #{row['parent']} is outside the snapshot and will be omitted") if row['parent'].present? && !item_keys.include?(row['parent'])
      end
      data.fetch('catalog').each do |row|
        error!('unknown_catalog_item', "Unknown catalog item #{row['item']}") unless item_keys.include?(row['item'])
        error!('unknown_catalog_document', "Unknown catalog document #{row['document']}") unless document_keys.include?(row['document'])
      end
    end

    def create_destination!(data)
      target = Project.create!(name: destination_attributes.fetch('name'), identifier: destination_attributes.fetch('identifier'),
                               cscode: destination_attributes.fetch('cscode'), description: destination_attributes['description'].to_s,
                               cosmosys_project_profile: profile_key)
      source = Project.find_by(identifier: data.dig('manifest', 'project_identifier'))
      copy_memberships!(source, target) if source
      names = data.fetch('items').map { |row| row['tracker'] }.reject(&:blank?).uniq
      target.trackers = (target.trackers.to_a + Tracker.where(name: names).to_a).uniq
      data.fetch('items').map { |row| row['version'] }.reject(&:blank?).uniq.each { |name| target.versions.create!(name: name) }
      data.fetch('items').map { |row| row['category'] }.reject(&:blank?).uniq.each { |name| target.issue_categories.create!(name: name) }
      target
    end

    def copy_memberships!(source, target)
      source.members.includes(:member_roles).each do |member|
        copy = target.members.create!(user_id: member.user_id)
        member.member_roles.each { |role| copy.member_roles.create!(role_id: role.role_id) }
      end
    end

    def prepare_rows!(data)
      initial = IssueStatus.sorted.first&.name
      data.fetch('items').each do |row|
        row['redmine_id'] = ''
        row['base_values'] = '{}'
        next unless mode == 'clean'
        row['status'], row['done_ratio'], row['start_date'], row['due_date'] = initial, '0', '', ''
      end
      data.fetch('documents').each { |row| row['redmine_id'] = ''; row['base_values'] = '{}' }
      data.fetch('catalog').each { |row| row['base_values'] = '{}' }
    end

    def apply_snapshot_hierarchy_and_relations!(rows, items)
      rows.each do |row|
        issue = items.fetch(row['csid']).reload
        parent = items[row['parent']]
        issue.update!(parent_issue_id: parent.id) if parent
        {'blocking_items' => 'blocks', 'precedent_items' => 'precedes', 'related_items' => 'relates'}.each do |field, type|
          row[field].to_s.split(',').map(&:strip).filter_map { |key| items[key] }.uniq.each do |from|
            IssueRelation.create!(issue_from: from, issue_to: issue, relation_type: type)
          end
        end
      end
    end

    def rewrite_snapshot_references!(data, items)
      replacements = data.fetch('items').to_h { |row| [row['csid'], items.fetch(row['csid']).csid] }
      data.fetch('catalog').each do |row|
        identity = OdsImportIdentity.find_by!(project: destination, export_id: transfer.export_id,
                                              row_uuid: row['row_uuid'], entity_type: 'Cosmosys::CatalogRef')
        replacements[row['markdown_reference']] = "document:di#{identity.entity_id}"
      end
      items.values.uniq.each do |issue|
        text = replacements.reduce(issue.description.to_s) { |memo, (from, to)| memo.gsub(from.to_s, to.to_s) }
        issue.update_columns(description: text, updated_on: Time.current) if text != issue.description.to_s
      end
    end

    def error!(code, message)
      transfer.events.create!(severity: 'error', code: code, message: message)
    end

    def warning!(code, message)
      transfer.events.create!(severity: 'warning', code: code, message: message)
    end
  end
end
