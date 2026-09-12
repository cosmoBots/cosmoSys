require 'digest'
require 'json'

module Cosmosys
  class ProjectCopyPlan
    VERIFIER_SALT = :cosmosys_project_copy_plan
    attr_reader :source, :user, :context, :destination_attributes, :external_relations,
                :identity_collisions

    def initialize(source:, user:, context:, destination_attributes:)
      @source = source
      @user = user
      @context = context
      raw_attributes = if destination_attributes.respond_to?(:to_unsafe_h)
                         destination_attributes.to_unsafe_h
                       else
                         destination_attributes.to_h
                       end
      @destination_attributes = raw_attributes.stringify_keys
      @identity_collisions = find_identity_collisions
      @external_relations = inspect_external_relations
    end

    def blocking_messages
      messages = []
      if identity_collisions.any?
        messages << I18n.t(:error_cosmosys_preserve_csid_collision,
                           csids: identity_collisions.sort.join(', '))
      end
      ambiguous = external_relations.select { |entry| entry[:classification] == 'ambiguous' }
      if ambiguous.any?
        messages << I18n.t(:error_cosmosys_copy_ambiguous_external_relations,
                           count: ambiguous.length)
      end
      messages
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

    def counts
      {
        items: context.copying?('issues') ? source.issues.count : 0,
        documents: context.copying?('documents') ? source.documents.count : 0,
        members: context.copying?('members') ? source.members.count : 0,
        internal_relations: internal_relation_count,
        external_relations: external_relations.length
      }
    end

    def relation_counts
      external_relations.group_by { |entry| entry[:classification] }
                        .transform_values(&:length)
    end

    private

    def parent
      @parent ||= Project.find_by(id: destination_attributes['parent_id'].presence)
    end

    def source_issue_ids
      @source_issue_ids ||= source.issues.pluck(:id)
    end

    def find_identity_collisions
      return [] unless context.identity_mode == 'preserve' && context.copying?('issues') && parent

      csids = source.issues.where.not(csid: nil).pluck(:csid)
      return [] if csids.empty?

      Issue.where(project_id: parent.root.self_and_descendants.select(:id))
           .where('LOWER(csid) IN (?)', csids.map(&:downcase)).pluck(:csid).uniq
    end

    def inspect_external_relations
      return [] unless context.copying?('issues') && source_issue_ids.any?

      IssueRelation.where('issue_from_id IN (?) OR issue_to_id IN (?)', source_issue_ids, source_issue_ids)
                   .order(:id).filter_map do |relation|
        from_local = source_issue_ids.include?(relation.issue_from_id)
        to_local = source_issue_ids.include?(relation.issue_to_id)
        next if from_local && to_local

        local_id = from_local ? relation.issue_from_id : relation.issue_to_id
        external_id = from_local ? relation.issue_to_id : relation.issue_from_id
        external = Issue.find_by(id: external_id)
        next relation_entry(relation, local_id, external_id, from_local, nil, 'lost') unless external

        unless Issue.visible(user).where(id: external.id).exists?
          next relation_entry(relation, local_id, nil, from_local, nil, 'unauthorized')
        end

        classification, target_id = classify_external(external)
        relation_entry(relation, local_id, external.id, from_local, external, classification, target_id)
      end
    end

    def classify_external(external)
      return ['pending', nil] unless parent
      return ['retain_original', external.id] if external.project.root.id == parent.root.id
      return ['pending', nil] if external.csid.blank?

      matches = Issue.where(project_id: parent.root.self_and_descendants.select(:id))
                     .where('LOWER(csid) = ?', external.csid.downcase).pluck(:id)
      return ['remap_by_csid', matches.first] if matches.one?
      return ['ambiguous', nil] if matches.many?

      ['pending', nil]
    end

    def relation_entry(relation, local_id, external_id, from_local, external, classification, target_id = nil)
      {
        source_relation_id: relation.id,
        local_source_id: local_id,
        local_side: from_local ? 'from' : 'to',
        external_source_id: external_id,
        external_csid: external&.csid,
        external_subject: external&.subject,
        external_project: external&.project&.identifier,
        relation_type: relation.relation_type,
        delay: relation.delay,
        classification: classification,
        target_id: target_id
      }
    end

    def internal_relation_count
      return 0 unless context.copying?('issues') && source_issue_ids.any?

      IssueRelation.where(issue_from_id: source_issue_ids, issue_to_id: source_issue_ids).count
    end

    def canonical_payload
      {
        source_id: source.id,
        source_updated_on: source.updated_on&.utc&.iso8601(6),
        destination: destination_attributes.slice('name', 'identifier', 'cscode', 'parent_id'),
        mode: context.mode,
        identity_mode: context.identity_mode,
        selected_parts: context.selected_parts.sort,
        counts: counts,
        identity_collisions: identity_collisions.sort,
        external_relations: external_relations
      }
    end
  end
end
