require 'stringio'

module Cosmosys
  class BrandingAsset < ActiveRecord::Base
    self.table_name = 'cosmosys_branding_assets'

    MAX_BYTES = 2.megabytes
    FORMATS = {
      'png' => { content_type: 'image/png', signature: ->(data) { data.start_with?("\x89PNG\r\n\x1a\n".b) } },
      'webp' => { content_type: 'image/webp', signature: ->(data) { data.start_with?('RIFF') && data.byteslice(8, 4) == 'WEBP' } },
      'jpg' => { content_type: 'image/jpeg', signature: ->(data) { data.start_with?("\xff\xd8\xff".b) } },
      'jpeg' => { content_type: 'image/jpeg', signature: ->(data) { data.start_with?("\xff\xd8\xff".b) } }
    }.freeze

    class InvalidUpload < StandardError; end

    belongs_to :project, optional: true
    belongs_to :created_by, class_name: 'User'
    has_one :attachment, as: :container, dependent: :destroy, inverse_of: :container

    before_validation :assign_scope_key
    validates :project_id, uniqueness: true, allow_nil: true
    validates :scope_key, presence: true, uniqueness: true
    validates :diffuse_effect, inclusion: { in: [true, false] }

    def self.instance_asset
      find_by(project_id: nil)
    end

    def self.validate_upload!(upload)
      return nil unless upload.respond_to?(:read)

      data = upload.read
      upload.rewind if upload.respond_to?(:rewind)
      extension = File.extname(upload.original_filename.to_s).delete_prefix('.').downcase
      format = FORMATS[extension]
      raise InvalidUpload, I18n.t(:error_cosmosys_branding_format) unless format && format[:signature].call(data)
      raise InvalidUpload, I18n.t(:error_cosmosys_branding_size) if data.empty? || data.bytesize > MAX_BYTES

      { data: data, filename: upload.original_filename.to_s, content_type: format[:content_type] }
    end

    def self.replace!(project:, upload:, diffuse_effect:, author: User.current)
      validated = validate_upload!(upload)
      current = find_by(project_id: project&.id)
      return current unless validated

      replacement = nil
      transaction do
        replacement = current || create!(project: project, created_by: author, diffuse_effect: diffuse_effect)
        previous_attachment = replacement.attachment
        new_attachment = Attachment.create!(
          container: replacement,
          author: author,
          file: StringIO.new(validated[:data]),
          filename: validated[:filename],
          content_type: validated[:content_type]
        )
        replacement.update!(created_by: author, diffuse_effect: diffuse_effect)
        previous_attachment&.destroy! unless previous_attachment == new_attachment
      end
      replacement.association(:attachment).reset
      replacement
    rescue ActiveRecord::RecordNotUnique
      raise InvalidUpload, I18n.t(:error_cosmosys_branding_concurrent_update)
    end

    def visible?(user = User.current)
      project.nil? || project.visible?(user)
    end

    private

    def assign_scope_key
      self.scope_key = project_id ? "project:#{project_id}" : 'instance'
    end
  end
end
