require_dependency 'issue_status'

module Cosmosys
  module IssueStatusPatch
    OUTCOMES = %w[successful unsuccessful].freeze

    def self.included(base)
      base.class_eval do
        safe_attributes 'csys_closed_outcome', 'csys_maturity'
        validates :csys_closed_outcome, inclusion: { in: OUTCOMES }, allow_blank: true, if: :cosmosys_outcome_column_available?
        validates :csys_maturity,
                  numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                  allow_nil: true,
                  if: :cosmosys_maturity_column_available?
        validate :cosmosys_outcome_requires_closed_status, if: :cosmosys_outcome_column_available?
        after_commit :cosmosys_invalidate_diagrams_after_maturity_change, on: :update
      end
    end

    def cosmosys_successfully_closed?
      is_closed? && csys_closed_outcome == 'successful'
    end

    def cosmosys_unsuccessfully_closed?
      is_closed? && csys_closed_outcome == 'unsuccessful'
    end

    def cosmosys_maturity_level
      csys_maturity if cosmosys_maturity_column_available?
    end

    private

    def cosmosys_outcome_column_available?
      has_attribute?(:csys_closed_outcome)
    end

    def cosmosys_maturity_column_available?
      has_attribute?(:csys_maturity)
    end

    def cosmosys_outcome_requires_closed_status
      return if csys_closed_outcome.blank? || is_closed?

      errors.add(:csys_closed_outcome, :invalid)
    end

    def cosmosys_invalidate_diagrams_after_maturity_change
      return unless previous_changes.key?('csys_maturity')
      return unless defined?(Cosmosys::Diagram) && Cosmosys::Diagram.table_exists?

      Cosmosys::Diagram.update_all(obsolete: true)
    end
  end
end
