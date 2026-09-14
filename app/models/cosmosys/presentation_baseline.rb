module Cosmosys
  class PresentationBaseline < ActiveRecord::Base
    self.table_name = 'cosmosys_presentation_baselines'

    belongs_to :issue
    belongs_to :captured_status, class_name: 'IssueStatus', optional: true

    validates :attribute_name, inclusion: { in: %w[description blocking_context] }
    validates :resolved_sha256, presence: true
    validates :captured_maturity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    def ledger
      JSON.parse(ledger_json.presence || '[]')
    rescue JSON::ParserError
      []
    end
  end
end
