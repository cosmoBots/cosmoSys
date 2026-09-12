require 'digest'
require 'json'

module Cosmosys
  class ProjectSnapshotMaterializationPlan
    VERIFIER_SALT = :cosmosys_project_snapshot_materialization_plan

    attr_reader :source, :attributes, :identity_collisions, :missing_trackers,
                :missing_custom_fields, :missing_assets

    def initialize(source:, attributes:)
      @source = source
      raw = attributes.respond_to?(:to_unsafe_h) ? attributes.to_unsafe_h : attributes.to_h
      @attributes = raw.stringify_keys
      validate_schema!
      @identity_collisions = find_identity_collisions
      @missing_trackers = find_missing_trackers
      @missing_custom_fields = find_missing_custom_fields
      @missing_assets = find_missing_assets
    end

    def blocking_messages
      messages = []
      profile = project_payload.fetch('profile')
      messages << "Unknown project profile #{profile}" unless ProjectProfileRegistry.registered?(profile)
      if Project.exists?(identifier: attributes.fetch('identifier'))
        messages << I18n.t(:error_cosmosys_snapshot_identifier_taken)
      end
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

    def counts
      {
        items: content.fetch('items').length,
        documents: content.fetch('documents').length,
        internal_relations: content.fetch('relations').length,
        attachments: required_asset_digests.length
      }
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

    def project_payload
      content.fetch('project')
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

      csids = content.fetch('items').filter_map { |row| row['csid']&.downcase }
      return [] if csids.empty?

      Issue.where(project_id: parent.root.self_and_descendants.select(:id))
           .where('LOWER(csid) IN (?)', csids).pluck(:csid).uniq
    end

    def find_missing_trackers
      keys = content.fetch('items').filter_map { |row| row.dig('tracker', 'key') }.uniq
      available = Tracker.where(csys_key: keys).or(Tracker.where(name: keys)).pluck(:csys_key, :name).flatten.compact
      keys - available
    end

    def find_missing_custom_fields
      definitions = content.fetch('items').flat_map { |row| row.fetch('custom_fields', []) }
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

    def asset_path(digest)
      return source.asset_path(digest) if source.respond_to?(:asset_path)

      source.attachments.find_by!(digest: digest).diskfile
    end

    def required_asset_digests
      @required_asset_digests ||= (
        content.fetch('items').flat_map { |row| row.fetch('attachments') } +
        content.fetch('documents').flat_map { |row| row.fetch('attachments') }
      ).map { |row| row.fetch('content_sha256') }.uniq.sort
    end

    def canonical_payload
      {
        source_digest: manifest.fetch('content_sha256'),
        destination: attributes.slice('name', 'identifier', 'cscode', 'parent_id', 'identity_mode'),
        counts: counts,
        identity_collisions: identity_collisions.sort,
        missing_trackers: missing_trackers.sort,
        missing_custom_fields: missing_custom_fields.sort,
        missing_assets: missing_assets.sort
      }
    end
  end
end
