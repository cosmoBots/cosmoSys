require_dependency 'tracker'

module Cosmosys
  module TrackerPatch
    def self.included(base)
      base.class_eval do
        validates :csys_item_kind, format: { with: /\A[a-z][a-z0-9_]*\z/ }, if: :cosmosys_kind_columns_available?
        before_validation :cosmosys_normalize_item_kind
        after_commit :cosmosys_invalidate_kind_diagrams, on: :update, if: :saved_change_to_csys_item_kind?
        validate :cosmosys_protect_structural_tracker
        before_destroy :cosmosys_prevent_structural_tracker_destroy
      end
    end

    def cosmosys_item_kind_profile
      Cosmosys::ItemKindRegistry.fetch(csys_item_kind)
    end

    def cosmosys_item_kind_registered?
      Cosmosys::ItemKindRegistry.registered?(csys_item_kind)
    end

    def cosmosys_negative_tracker?
      csys_item_kind.to_s == 'negative'
    end

    private

    def cosmosys_kind_columns_available?
      has_attribute?(:csys_item_kind) && has_attribute?(:csys_key)
    end

    def cosmosys_protect_structural_tracker
      return unless cosmosys_kind_columns_available?
      return if csys_key.blank?
      contract = Cosmosys::ProjectProfileRegistry.all.flat_map(&:required_trackers).find { |entry| entry[:key] == csys_key }
      return unless contract
      errors.add(:csys_key, 'is managed by a cosmoSys project profile') if will_save_change_to_csys_key?
      errors.add(:csys_item_kind, 'is required by a cosmoSys project profile') if will_save_change_to_csys_item_kind? && csys_item_kind != contract[:item_profile]
    end

    def cosmosys_prevent_structural_tracker_destroy
      if projects.exists?
        errors.add(:base, I18n.t(:error_cosmosys_tracker_enabled))
        throw :abort
      end

      return true unless cosmosys_kind_columns_available?
      return true if csys_key.blank?
      return true unless Cosmosys::ProjectProfileRegistry.all.any? { |profile| profile.required_trackers.any? { |entry| entry[:key] == csys_key } }
      errors.add(:base, I18n.t(:error_cosmosys_tracker_required))
      throw :abort
    end

    def cosmosys_normalize_item_kind
      return unless cosmosys_kind_columns_available?
      self.csys_item_kind = Cosmosys::ItemKindRegistry.normalize_key(csys_item_kind)
    end

    def cosmosys_invalidate_kind_diagrams
      issue_scope = Issue.where(tracker_id: id)
      project_ids = issue_scope.distinct.pluck(:project_id)
      Cosmosys::Diagram.where(issue_id: issue_scope.select(:id)).update_all(state: 'obsolete', updated_at: Time.current)
      Cosmosys::Diagram.where(project_id: project_ids).update_all(state: 'obsolete', updated_at: Time.current)
    end
  end
end
