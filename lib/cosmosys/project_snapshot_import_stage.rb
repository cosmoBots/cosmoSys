require 'digest'
require 'securerandom'
require 'fileutils'
require 'json'
require 'time'

module Cosmosys
  # Bounded, ephemeral staging of an uploaded portable `.csys` package between
  # the signed intermediate confirmation screen and the explicit confirmation.
  #
  # The uploaded package is validated once and retained only for the bounded
  # confirmation lifetime. The staged copy is removed on completion,
  # cancellation or expiry. Nothing here writes domain records: it only stores
  # the uploaded bytes under an anonymous staged path keyed by a high-entropy
  # opaque token that is carried across the confirmation screen.
  class ProjectSnapshotImportStage
    ROOT = 'cosmosys/snapshot-import'.freeze
    LIFETIME = 30.minutes
    FILENAME = 'package.csys'.freeze
    METADATA_FILENAME = 'metadata.json'.freeze

    class << self
      def root
        Rails.root.join('tmp', ROOT)
      end

      # Copies the uploaded tempfile into a bounded stage. Raises when the
      # upload is missing or larger than max_bytes. Returns the opaque token.
      def create(upload_path, user:, project:, max_bytes: 500.megabytes)
        size = File.size(upload_path)
        raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_upload_too_large) if size > max_bytes

        token = SecureRandom.urlsafe_base64(32)
        directory = File.join(root, token)
        FileUtils.mkdir_p(directory)
        File.open(upload_path, 'rb') do |input|
          File.open(directory_path(directory), 'wb') { |output| IO.copy_stream(input, output) }
        end
        write_metadata(directory, user: user, project: project)
        clear_outdated!
        token
      end

      # Returns the packaged path when the token names an unexpired stage,
      # otherwise nil. Opportunistically clears expired stages.
      def retrieve(token, user:, project:)
        directory = staged_directory(token)
        return nil unless directory && File.directory?(directory)

        metadata = read_metadata(directory)
        return nil unless owned_by?(metadata, user: user, project: project)
        return nil if expired?(metadata['created_at'].to_s)

        clear_outdated!
        directory_path(directory)
      end

      # Removes the staged package for the token. Idempotent.
      def cleanup(token, user:, project:)
        directory = staged_directory(token)
        if directory && File.directory?(directory) && owned_by?(read_metadata(directory), user: user, project: project)
          FileUtils.remove_entry(directory, true)
        end
        clear_outdated!
      end

      # Removes stages older than the bounded lifetime so failed, cancelled or
      # abandoned confirmations never accumulate.
      def clear_outdated!
        return unless File.directory?(root)

        Dir.each_child(root) do |token|
          directory = File.join(root, token)
          next unless File.directory?(directory)

          metadata = read_metadata(directory)
          FileUtils.remove_entry(directory, true) if expired?(metadata['created_at'].to_s)
        end
      rescue StandardError
        nil
      end

      def expired?(created_at_string, now: Time.now)
        created_at_string.empty? || (Time.parse(created_at_string) < (now - LIFETIME))
      rescue ArgumentError
        true
      end

      private

      def write_metadata(directory, user:, project:)
        File.write(File.join(directory, METADATA_FILENAME), JSON.generate(
          created_at: Time.now.utc.iso8601, user_id: user.id, project_id: project.id
        ))
      end

      def read_metadata(directory)
        JSON.parse(File.read(File.join(directory, METADATA_FILENAME)))
      rescue Errno::ENOENT, JSON::ParserError
        {}
      end

      def owned_by?(metadata, user:, project:)
        metadata['user_id'].to_i == user.id.to_i && metadata['project_id'].to_i == project.id.to_i
      end

      def staged_directory(token)
        return nil unless token.to_s.match?(/\A[A-Za-z0-9_-]{20,}\z/)

        File.join(root, token.to_s)
      end

      def directory_path(directory)
        File.join(directory, FILENAME)
      end
    end
  end
end
