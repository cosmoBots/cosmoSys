require 'digest'
require 'json'

module Cosmosys
  class ProjectSnapshotMaterializationPlan
    VERIFIER_SALT = :cosmosys_project_snapshot_materialization_plan

    attr_reader :source, :attributes, :identity_collisions, :missing_trackers,
                :missing_custom_fields, :missing_assets, :plugin_compatibility

    def initialize(source:, attributes:)
      @source = source
      raw = attributes.respond_to?(:to_unsafe_h) ? attributes.to_unsafe_h : attributes.to_h
      @attributes = raw.stringify_keys
      validate_schema!
      @identity_collisions = find_identity_collisions
      @missing_trackers = find_missing_trackers
      @missing_custom_fields = find_missing_custom_fields
      @missing_assets = find_missing_assets
      @plugin_compatibility = compare_plugins
    end

    def blocking_messages
      messages = []
      messages << I18n.t(:error_cosmosys_snapshot_ambiguous_roots) unless top_level_entries.one?
      project_entries.each do |entry|
        profile = entry.fetch('project').fetch('profile')
        messages << "Unknown project profile #{profile}" unless ProjectProfileRegistry.registered?(profile)
      end
      collisions = destination_projects.filter_map do |entry|
        entry[:identifier] if Project.exists?(identifier: entry[:identifier])
      end
      collisions.concat(
        destination_projects.group_by { |entry| entry[:identifier] }
                            .select { |_identifier, rows| rows.length > 1 }.keys
      )
      collisions.uniq!
      messages << I18n.t(:error_cosmosys_snapshot_identifiers_taken, identifiers: collisions.join(', ')) if collisions.any?
      invalid_identifiers = destination_projects.filter_map do |entry|
        probe = Project.new(name: entry[:name], identifier: entry[:identifier], cscode: entry[:cscode])
        entry[:identifier] unless probe.valid? || probe.errors[:identifier].empty?
      end
      if invalid_identifiers.any?
        messages << I18n.t(:error_cosmosys_snapshot_identifiers_invalid,
                           identifiers: invalid_identifiers.join(', '))
      end
      duplicate_codes = destination_projects.group_by { |entry| entry[:cscode].to_s.downcase }
                                      .select { |_key, rows| rows.length > 1 }.keys
      messages << I18n.t(:error_cosmosys_snapshot_duplicate_cscodes, cscodes: duplicate_codes.join(', ')) if duplicate_codes.any?
      if identity_collisions.any?
        messages << I18n.t(:error_cosmosys_preserve_csid_collision,
                           csids: identity_collisions.sort.join(', '))
      end
      if missing_trackers.any?
        messages << I18n.t(:error_cosmosys_snapshot_trackers_missing,
                           trackers: missing_trackers.join(', '))
      end
      if missing_custom_fields.any?
        messages << I18n.t(:error_cosmosys_snapshot_custom_fields_missing,
                           fields: missing_custom_fields.join(', '))
      end
      if missing_assets.any?
        messages << I18n.t(:error_cosmosys_snapshot_assets_missing,
                           count: missing_assets.length)
      end
      messages
    end

    def destination_projects
      @destination_projects ||= begin
        root_entry = top_level_entries.first || project_entries.first
        source_root_identifier = root_entry.dig('project', 'identifier').to_s
        project_entries.map do |entry|
          source = entry.fetch('project')
          root = entry == root_entry
          source_identifier = source.fetch('identifier').to_s
          suffix = source_identifier.start_with?("#{source_root_identifier}-") ?
            source_identifier.delete_prefix(source_root_identifier) : "-p#{entry.fetch('source_id')}"
          generated_identifier = "#{attributes.fetch('identifier')}#{suffix}"
          {
            key: entry.fetch('key'), parent_key: entry['parent_key'], source: source,
            name: root ? attributes.fetch('name') : source.fetch('name'),
            identifier: root ? attributes.fetch('identifier') :
              (project_identifier_overrides[entry.fetch('source_id').to_s].presence || generated_identifier),
            cscode: root ? (attributes['cscode'].presence || source.fetch('cscode')) : source.fetch('cscode')
          }
        end
      end
    end

    def counts
      {
        projects: project_entries.length,
        items: items.length,
        documents: documents.length,
        internal_relations: content.fetch('relations').length,
        attachments: required_asset_digests.length
      }
    end

    def plugin_warnings
      plugin_compatibility.select { |entry| %w[missing older].include?(entry.fetch(:status)) }
    end

    def digest
      Digest::SHA256.hexdigest(JSON.generate(canonical_payload))
    end

    def confirmation_token
      Rails.application.message_verifier(VERIFIER_SALT).generate(digest)
    end

    def self.verified_digest(token)
      Rails.application.message_verifier(VERIFIER_SALT).verify(token.to_s)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    private

    def manifest
      @manifest ||= source.manifest
    end

    def content
      @content ||= manifest.fetch('content')
    end

    def project_entries
      content.fetch('projects')
    end

    def top_level_entries
      keys = project_entries.map { |entry| entry.fetch('key') }.to_set
      project_entries.select { |entry| entry['parent_key'].blank? || !keys.include?(entry['parent_key']) }
    end

    def items
      project_entries.flat_map { |entry| entry.fetch('items') }
    end

    def documents
      project_entries.flat_map { |entry| entry.fetch('documents') }
    end

    def validate_schema!
      return if manifest['schema'] == 'cosmosys-project-snapshot' &&
                manifest['schema_version'].to_s == ProjectSnapshotCapture::SCHEMA_VERSION

      raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_schema)
    end

    def parent
      return if attributes['parent_id'].blank?

      @parent ||= Project.find(attributes['parent_id'])
    end

    def identity_mode
      ProjectCopyContext::IDENTITY_MODES.include?(attributes['identity_mode'].to_s) ?
        attributes['identity_mode'].to_s : 'preserve'
    end

    def find_identity_collisions
      return [] unless identity_mode == 'preserve' && parent

      csids = items.filter_map { |row| row['csid']&.downcase }
      return [] if csids.empty?

      tree_root = parent.root || parent
      Issue.where(project_id: tree_root.self_and_descendants.select(:id))
           .where('LOWER(csid) IN (?)', csids).pluck(:csid).uniq
    end

    def find_missing_trackers
      keys = items.filter_map { |row| row.dig('tracker', 'key') }.uniq
      available = Tracker.where(csys_key: keys).or(Tracker.where(name: keys)).pluck(:csys_key, :name).flatten.compact
      keys - available
    end

    def find_missing_custom_fields
      definitions = items.flat_map { |row| row.fetch('custom_fields', []) }
                           .map { |entry| [entry.fetch('name'), entry.fetch('format')] }.uniq
      definitions.reject do |name, format|
        IssueCustomField.where(name: name, field_format: format).exists?
      end.map(&:first)
    end

    def find_missing_assets
      required_asset_digests.reject do |digest|
        begin
          File.file?(asset_path(digest))
        rescue ActiveRecord::RecordNotFound, KeyError, ProjectSnapshotPackageError
          false
        end
      end
    end

    def compare_plugins
      installed = Redmine::Plugin.all.index_by { |plugin| plugin.id.to_s }
      content.fetch('platform', {}).fetch('plugins', []).map do |captured|
        plugin = installed[captured.fetch('id')]
        status = if plugin.nil?
                   'missing'
                 elsif older_version?(plugin.version.to_s, captured.fetch('version'))
                   'older'
                 else
                   'available'
                 end
        { id: captured.fetch('id'), name: captured.fetch('name'),
          source_version: captured.fetch('version'),
          destination_version: plugin&.version&.to_s, status: status }
      end
    end

    def older_version?(destination, source)
      Gem::Version.new(destination) < Gem::Version.new(source)
    rescue ArgumentError
      destination != source
    end

    def asset_path(digest)
      return source.asset_path(digest) if source.respond_to?(:asset_path)

      source.attachments.find_by!(digest: digest).diskfile
    end

    def required_asset_digests
      @required_asset_digests ||= (
        items.flat_map { |row| row.fetch('attachments') } +
        documents.flat_map { |row| row.fetch('attachments') }
      ).map { |row| row.fetch('content_sha256') }.uniq.sort
    end

    def canonical_payload
      {
        source_digest: manifest.fetch('content_sha256'),
        destination: attributes.slice('name', 'identifier', 'cscode', 'parent_id', 'identity_mode'),
        destination_projects: destination_projects.map { |entry| entry.slice(:key, :parent_key, :identifier, :cscode) },
        counts: counts,
        identity_collisions: identity_collisions.sort,
        missing_trackers: missing_trackers.sort,
        missing_custom_fields: missing_custom_fields.sort,
        missing_assets: missing_assets.sort,
        plugin_compatibility: plugin_compatibility
      }
    end

    def project_identifier_overrides
      @project_identifier_overrides ||= begin
        raw = attributes['project_identifiers'] || {}
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        raw.to_h.stringify_keys
      end
    end
  end
end
