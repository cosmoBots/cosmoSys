require 'stringio'
require 'zip'
require 'digest'

module Cosmosys
  class ProjectSnapshotPackage
    MANIFEST_PATH = 'manifest.json'.freeze

    def initialize(snapshot)
      @snapshot = snapshot
    end

    def data
      Zip::OutputStream.write_buffer do |archive|
        archive.put_next_entry(MANIFEST_PATH)
        archive.write(snapshot.manifest_json)

        snapshot.attachments.sort_by(&:digest).each do |attachment|
          verify!(attachment)
          archive.put_next_entry("assets/sha256/#{attachment.digest}")
          File.open(attachment.diskfile, 'rb') { |file| IO.copy_stream(file, archive) }
        end
      end.string
    end

    private

    attr_reader :snapshot

    def verify!(attachment)
      path = attachment.diskfile
      raise ActiveRecord::RecordNotFound, "Snapshot asset is unavailable: #{attachment.digest}" unless File.file?(path)
      raise ActiveRecord::RecordInvalid, attachment unless Digest::SHA256.file(path).hexdigest == attachment.digest
    end
  end
end
