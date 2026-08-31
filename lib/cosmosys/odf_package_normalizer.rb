require 'stringio'
require 'zip'
require 'zlib'

module Cosmosys
  class OdfPackageNormalizer
    class InvalidPackage < StandardError; end

    def self.call(data, expected_mimetype:)
      new(data, expected_mimetype: expected_mimetype).call
    end

    def initialize(data, expected_mimetype:)
      @data = data.to_s.b
      @expected_mimetype = expected_mimetype.to_s
    end

    def call
      entries = read_entries
      mimetype = entries.find { |entry| entry.fetch(:name) == 'mimetype' }
      raise InvalidPackage, 'OpenDocument package has no mimetype entry' unless mimetype
      raise InvalidPackage, "Unexpected OpenDocument mimetype #{mimetype.fetch(:data).inspect}" unless mimetype.fetch(:data) == @expected_mimetype

      output = Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry(stored_mimetype_entry(mimetype.fetch(:data)))
        zip.write(mimetype.fetch(:data))

        entries.each do |entry|
          next if entry.fetch(:name) == 'mimetype'

          zip.put_next_entry(
            entry.fetch(:name),
            entry.fetch(:comment),
            entry.fetch(:extra),
            entry.fetch(:compression_method)
          )
          zip.write(entry.fetch(:data)) unless entry.fetch(:directory)
        end
      end
      output.string
    rescue Zip::Error => error
      raise InvalidPackage, "Invalid OpenDocument ZIP package: #{error.message}"
    end

    private

    def stored_mimetype_entry(data)
      entry = Zip::Entry.new('', 'mimetype', compression_method: Zip::Entry::STORED)
      entry.size = data.bytesize
      entry.compressed_size = data.bytesize
      entry.crc = Zlib.crc32(data)
      entry
    end

    def read_entries
      entries = nil
      Zip::File.open_buffer(StringIO.new(@data)) do |archive|
        entries = archive.entries.map do |entry|
          {
            name: entry.name,
            comment: entry.comment,
            extra: entry.extra.to_s,
            compression_method: entry.compression_method,
            directory: entry.directory?,
            data: entry.directory? ? ''.b : entry.get_input_stream.read
          }
        end
      end
      entries || []
    end
  end
end
