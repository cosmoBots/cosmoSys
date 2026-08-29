module Cosmosys
  module IssueRelationPatch
    extend ActiveSupport::Concern

    included do
      safe_attributes 'csys_restricted'
      validate :cosmosys_restricted_only_for_precedence
    end

    private

    def cosmosys_restricted_only_for_precedence
      return unless csys_restricted?
      return if relation_type == IssueRelation::TYPE_PRECEDES

      errors.add(:csys_restricted, I18n.t(:text_cosmosys_restricted_requires_precedence))
    end
  end
end
