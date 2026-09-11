require_dependency 'issue_status'

module Cosmosys
  module IssueStatusPatch
    OUTCOMES = %w[successful unsuccessful].freeze

    def self.included(base)
      base.class_eval do
        safe_attributes 'csys_closed_outcome'
        validates :csys_closed_outcome, inclusion: { in: OUTCOMES }, allow_blank: true, if: :cosmosys_outcome_column_available?
        validate :cosmosys_outcome_requires_closed_status, if: :cosmosys_outcome_column_available?
      end
    end

    def cosmosys_successfully_closed?
      is_closed? && csys_closed_outcome == 'successful'
    end

    def cosmosys_unsuccessfully_closed?
      is_closed? && csys_closed_outcome == 'unsuccessful'
    end

    private

    def cosmosys_outcome_column_available?
      has_attribute?(:csys_closed_outcome)
    end

    def cosmosys_outcome_requires_closed_status
      return if csys_closed_outcome.blank? || is_closed?

      errors.add(:csys_closed_outcome, :invalid)
    end
  end
end
