require 'json'

module Cosmosys
  class ProjectSnapshot < ActiveRecord::Base
    self.table_name = 'cosmosys_project_snapshots'

    belongs_to :project
    belongs_to :created_by, class_name: 'User'

    validates :project, :created_by, :schema_version, :content_sha256, :manifest_json, presence: true
    validates :content_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :name, length: { maximum: 255 }, allow_blank: true

    attr_readonly :project_id, :created_by_id, :schema_version, :content_sha256,
                  :manifest_json, :item_count, :document_count, :relation_count

    scope :recent_first, -> { order(created_at: :desc, id: :desc) }

    def manifest
      JSON.parse(manifest_json)
    end

    def readable_by?(user)
      user&.admin? || created_by_id == user&.id
    end
  end
end
