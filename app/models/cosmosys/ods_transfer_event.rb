require 'json'

module Cosmosys
  class OdsTransferEvent < ActiveRecord::Base
    self.table_name = 'cosmosys_ods_transfer_events'

    belongs_to :transfer,
               class_name: 'Cosmosys::OdsTransfer',
               foreign_key: :ods_transfer_id,
               inverse_of: :events

    validates :severity, inclusion: { in: %w[info warning conflict error] }
    validates :code, presence: true

    def details
      JSON.parse(details_json.presence || '{}')
    rescue JSON::ParserError
      {}
    end

    def details=(value)
      self.details_json = JSON.generate(value || {})
    end
  end
end
