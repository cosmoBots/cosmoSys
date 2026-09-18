require 'json'
require 'stringio'
require 'zlib'

module Cosmosys
  class ProjectSnapshot < ActiveRecord::Base
    self.table_name = 'cosmosys_project_snapshots'

    belongs_to :project
    belongs_to :created_by, class_name: 'User'
    has_many :attachments, as: :container, dependent: :destroy, inverse_of: :container

    validates :project, :created_by, :schema_version, :content_sha256, :manifest_gzip, presence: true
    validates :content_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :name, length: { maximum: 255 }, allow_blank: true

    attr_readonly :project_id, :created_by_id, :schema_version, :content_sha256,
                  :manifest_gzip, :item_count, :document_count, :relation_count,
                  :wiki_page_count

    scope :recent_first, -> { order(created_at: :desc, id: :desc) }

    def manifest
      JSON.parse(manifest_json)
    end

    def manifest_json
      Zlib::GzipReader.new(StringIO.new(manifest_gzip)).read
    end

    def project_count
      manifest.fetch('content').fetch('projects').length
    end

    def readable_by?(user)
      user&.admin? || created_by_id == user&.id
    end

    def visible?(user = User.current)
      readable_by?(user) && project.visible?(user)
    end
  end
end
