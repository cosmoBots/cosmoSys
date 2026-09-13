require 'digest'
require 'json'

module Cosmosys
  class ProjectTreeCopyPlan
    VERIFIER_SALT = :cosmosys_project_tree_copy_plan

    attr_reader :source, :user, :context, :selected_projects, :snapshot_source,
                :materialization_plan

    def initialize(source:, user:, context:, destination_attributes:, project_ids:, project_identifiers: nil)
      @source = source
      @user = user
      @context = context
      @selected_projects = resolve_selection(project_ids)
      @snapshot_source = ProjectSnapshotCapture.new(
        source, user: user, projects: selected_projects.map(&:id)
      )
      attributes = destination_attributes.respond_to?(:to_unsafe_h) ?
        destination_attributes.to_unsafe_h : destination_attributes.to_h
      overrides = project_identifiers.respond_to?(:to_unsafe_h) ?
        project_identifiers.to_unsafe_h : project_identifiers.to_h
      @materialization_plan = ProjectSnapshotMaterializationPlan.new(
        source: snapshot_source,
        attributes: attributes.merge(
          'identity_mode' => context.identity_mode,
          'project_identifiers' => overrides,
          'primary_source_id' => source.id,
          'allow_multiple_roots' => true
        )
      )
    end

    def multi_project?
      true
    end

    def executable?
      true
    end

    def blocking_messages
      materialization_plan.blocking_messages
    end

    def counts
      entries = snapshot_source.manifest.dig('content', 'projects')
      items = context.copying?('issues') ? entries.sum { |entry| entry.fetch('items').length } : 0
      documents = context.copying?('documents') ? entries.sum { |entry| entry.fetch('documents').length } : 0
      attachment_rows = []
      attachment_rows.concat(entries.flat_map { |entry| entry.fetch('items').flat_map { |row| row.fetch('attachments') } }) if context.copying?('issues')
      attachment_rows.concat(entries.flat_map { |entry| entry.fetch('documents').flat_map { |row| row.fetch('attachments') } }) if context.copying?('documents')
      {
        projects: entries.length,
        items: items,
        documents: documents,
        members: context.copying?('members') ? selected_projects.sum { |project| project.members.count } : 0,
        internal_relations: context.copying?('issues') ? snapshot_source.manifest.dig('content', 'relations').length : 0,
        external_relations: context.copying?('issues') ? external_relations.length : 0,
        attachments: attachment_rows.map { |row| row.fetch('content_sha256') }.uniq.length
      }
    end

    def destination_projects
      materialization_plan.destination_projects
    end

    def primary_project?(entry)
      entry.fetch(:key) == "project:#{source.id}"
    end

    def external_relations
      @external_relations ||= snapshot_source.manifest.dig('content', 'external_relations').map do |relation|
        {
          relation_type: relation.fetch('type'),
          external_csid: relation['external_csid'],
          external_source_id: nil,
          external_subject: nil,
          external_project: relation['external_project_identifier'],
          classification: :lost
        }
      end
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

    def resolve_selection(ids)
      selected = ProjectSnapshotSelection.new(source, user: user).resolve(ids)
      raise ProjectCopyError, I18n.t(:error_cosmosys_copy_source_required) unless selected.include?(source)

      selected
    end

    def canonical_payload
      {
        snapshot_digest: snapshot_source.manifest.fetch('content_sha256'),
        project_ids: selected_projects.map(&:id),
        mode: context.mode,
        identity_mode: context.identity_mode,
        selected_parts: context.selected_parts.sort,
        destination: materialization_plan.attributes.slice('name', 'identifier', 'cscode', 'parent_id'),
        materialization_digest: materialization_plan.digest
      }
    end
  end
end
