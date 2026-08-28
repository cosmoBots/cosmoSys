require 'digest'

module Cosmosys
  class OdsExportJob < ActiveJob::Base
    queue_as :default

    def perform(transfer_id, base_url, writer = Cosmosys::OdsExportService::DEFAULT_WRITER)
      transfer = Cosmosys::OdsTransfer.find(transfer_id)
      User.current = transfer.user
      progress = Cosmosys::ProgressReporter.new(transfer, state: 'generating')
      progress.call(1, 'opening')
      result = Cosmosys::OdsExportService.new(
        transfer.project,
        user: transfer.user,
        base_url: base_url,
        include_subprojects: transfer.include_subprojects,
        progress: progress,
        writer: writer
      ).call
      transfer.update!(
        state: 'applied',
        original_filename: result.filename,
        content_type: result.content_type,
        byte_size: result.data.bytesize,
        file_sha256: Digest::SHA256.hexdigest(result.data),
        payload_sha256: result.payload_sha256,
        export_id: result.export_id,
        summary: result.summary.merge('progress' => 100, 'progress_phase' => 'completed'),
        file_data: result.data
      )
    rescue StandardError => error
      if transfer&.persisted?
        transfer.events.create!(severity: 'error', code: 'export_failed', message: error.message)
        transfer.update!(state: 'failed', summary: transfer.summary.merge('progress_phase' => 'failed'))
      end
      Rails.logger.error("cosmoSys asynchronous ODS export failed: #{error.class}: #{error.message}")
    ensure
      User.current = nil
    end

  end
end
