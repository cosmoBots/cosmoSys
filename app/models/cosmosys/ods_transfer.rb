require 'json'

module Cosmosys
  class OdsTransfer < ActiveRecord::Base
    self.table_name = 'cosmosys_ods_transfers'

    DIRECTIONS = %w[export import materialize].freeze
    STATES = %w[queued generating uploaded analysing analysed awaiting_confirmation applying applied rejected failed superseded].freeze
    PENDING_IMPORT_STATES = %w[uploaded analysing analysed awaiting_confirmation].freeze

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

    after_create :supersede_older_pending_imports

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
      state == 'awaiting_confirmation' && !superseded_by_newer_import?
    end

    def superseded?
      state == 'superseded'
    end

    def superseded_by_newer_import?
      return false unless direction == 'import' && persisted?

      self.class.where(project_id: project_id, direction: 'import').where('id > ?', id).exists?
    end

    def export_payload
      direction == 'export' ? file_data : result_data
    end

    def export_writer
      summary['writer'].presence || 'indexed'
    end

    private

    def supersede_older_pending_imports
      return unless direction == 'import'

      project.with_lock do
        self.class.where(project_id: project_id, direction: 'import', state: PENDING_IMPORT_STATES)
                  .where('id < ?', id).find_each do |older|
          older_summary = older.summary.merge(
            'progress_phase' => 'superseded',
            'superseded_by_transfer_id' => id
          )
          older.update_columns(
            state: 'superseded',
            summary_json: JSON.generate(older_summary),
            file_data: nil,
            result_data: nil,
            updated_at: Time.current
          )
        end
      end
    end
  end
end
