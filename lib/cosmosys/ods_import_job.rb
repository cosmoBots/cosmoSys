module Cosmosys
  class OdsImportJob < ActiveJob::Base
    queue_as :default

    def perform(transfer_id, operation)
      transfer = Cosmosys::OdsTransfer.find(transfer_id)
      User.current = transfer.user
      progress = Cosmosys::ProgressReporter.new(transfer)
      service = Cosmosys::OdsImportService.new(transfer, user: transfer.user, progress: progress)

      case operation.to_s
      when 'analyse'
        service.analyse!
      when 'apply'
        service.apply!
      else
        raise ArgumentError, "Unsupported ODS import operation #{operation.inspect}"
      end
    rescue StandardError => error
      if transfer&.persisted?
        transfer.events.create!(severity: 'error', code: 'background_import_failed', message: error.message)
        transfer.update!(state: 'failed', summary: transfer.summary.merge('progress_phase' => 'failed'))
      end
      Rails.logger.error("cosmoSys asynchronous ODS import failed: #{error.class}: #{error.message}")
    ensure
      User.current = nil
    end
  end
end
