require 'json'

module Cosmosys
  class OdsTransfer < ActiveRecord::Base
    self.table_name = 'cosmosys_ods_transfers'

    DIRECTIONS = %w[export import materialize].freeze
    STATES = %w[queued generating uploaded analysed awaiting_confirmation applying applied rejected failed].freeze

    belongs_to :project
    belongs_to :user
    has_many :events,
             class_name: 'Cosmosys::OdsTransferEvent',
             foreign_key: :ods_transfer_id,
             inverse_of: :transfer,
             dependent: :delete_all

    validates :direction, inclusion: { in: DIRECTIONS }
    validates :state, inclusion: { in: STATES }
    validates :export_id, presence: true

    scope :recent_first, -> { order(created_at: :desc, id: :desc) }

    def summary
      JSON.parse(summary_json.presence || '{}')
    rescue JSON::ParserError
      {}
    end

    def summary=(value)
      self.summary_json = JSON.generate(value || {})
    end

    def applied?
      state == 'applied'
    end

    def applicable?
      state == 'awaiting_confirmation'
    end

    def export_payload
      direction == 'export' ? file_data : result_data
    end

    def export_writer
      summary['writer'].presence || 'indexed'
    end
  end
end
