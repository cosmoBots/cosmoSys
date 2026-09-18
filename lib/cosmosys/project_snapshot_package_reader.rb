require 'zip'
require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'

module Cosmosys
  class ProjectSnapshotPackageError < StandardError; end

  class ProjectSnapshotPackageReader
    MAX_MANIFEST_BYTES = 50.megabytes
    MAX_ARCHIVE_ENTRIES = 10_000
    MAX_ASSET_BYTES = 500.megabytes
    MAX_TOTAL_ASSET_BYTES = 2.gigabytes

    attr_reader :manifest

    def self.open(path)
      Dir.mktmpdir('cosmosys-snapshot-import') do |directory|
        source = new(path, directory).load!
        yield source
      end
    end

    def initialize(path, directory)
      @path = path.to_s
      @directory = directory
      @assets = {}
    end

    def load!
      Zip::File.open(path) do |archive|
        validate_archive_shape!(archive)
        entry = archive.find_entry(ProjectSnapshotPackage::MANIFEST_PATH)
        raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_manifest_missing) unless entry
        raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_manifest_too_large) if entry.size > MAX_MANIFEST_BYTES

        @manifest = JSON.parse(entry.get_input_stream.read)
        validate_manifest!
        extract_assets!(archive)
      end
      self
    rescue Zip::Error, JSON::ParserError => error
      raise ProjectSnapshotPackageError, error.message
    end

    def asset_path(digest)
      @assets.fetch(digest) do
        raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_asset_missing, digest: digest)
      end
    end

    private

    attr_reader :path, :directory

    def validate_manifest!
      unless manifest['schema'] == 'cosmosys-project-snapshot' &&
             manifest['schema_version'].to_s == ProjectSnapshotCapture::SCHEMA_VERSION
        raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_schema)
      end
      canonical = CanonicalJson.generate(manifest.fetch('content'))
      actual = Digest::SHA256.hexdigest(canonical)
      return if actual == manifest['content_sha256']

      raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_digest)
    end

    def extract_assets!(archive)
      total_bytes = 0
      required_assets.each do |digest|
        unless digest.match?(/\A[0-9a-f]{64}\z/)
          raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_asset_digest, digest: digest)
        end
        entry = archive.find_entry("assets/sha256/#{digest}")
        raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_asset_missing, digest: digest) unless entry
        if entry.size > MAX_ASSET_BYTES || (total_bytes += entry.size) > MAX_TOTAL_ASSET_BYTES
          raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_assets_too_large)
        end

        target = File.join(directory, digest)
        entry.get_input_stream do |input|
          File.open(target, 'wb') { |output| IO.copy_stream(input, output) }
        end
        unless Digest::SHA256.file(target).hexdigest == digest
          raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_asset_digest, digest: digest)
        end
        @assets[digest] = target
      end
    end

    def validate_archive_shape!(archive)
      entries = archive.entries
      if entries.length > MAX_ARCHIVE_ENTRIES || entries.map(&:name).uniq.length != entries.length
        raise ProjectSnapshotPackageError, I18n.t(:error_cosmosys_snapshot_archive_invalid)
      end
    end

    def required_assets
      content = manifest.fetch('content')
      projects = content.fetch('projects')
      wiki_attachments = projects.flat_map do |project|
        wiki = project['wiki']
        wiki && wiki['present'] ? wiki.fetch('pages') : []
      end.flat_map { |row| row.fetch('attachments') }
      (projects.flat_map { |project| project.fetch('items') }.flat_map { |row| row.fetch('attachments') } +
       projects.flat_map { |project| project.fetch('documents') }.flat_map { |row| row.fetch('attachments') } +
       wiki_attachments)
        .map { |row| row.fetch('content_sha256') }.uniq.sort
    end
  end
end
