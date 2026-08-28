require 'digest'
require 'fileutils'

module Cosmosys
  class TemplateAsset < ActiveRecord::Base
    self.table_name = 'cosmosys_template_assets'

    KINDS = %w[ods report].freeze
    MAX_BYTES = 20.megabytes

    belongs_to :created_by, class_name: 'User'
    has_many :ods_overriding_projects,
             class_name: 'Project',
             foreign_key: :cosmosys_ods_template_asset_id,
             inverse_of: :cosmosys_ods_template_asset
    has_many :report_overriding_projects,
             class_name: 'Project',
             foreign_key: :cosmosys_report_template_asset_id,
             inverse_of: :cosmosys_report_template_asset

    validates :name, :storage_key, :original_filename, :sha256, presence: true
    validates :kind, inclusion: { in: KINDS }
    validates :storage_key, uniqueness: true, format: { with: /\A[a-f0-9-]+\.(?:ods|odt)\z/ }
    validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_BYTES }

    scope :available_ods, -> { where(kind: 'ods', active: true).order(:name, :id) }
    scope :available_reports, -> { where(kind: 'report', active: true).order(:name, :id) }

    def self.storage_root(kind = 'ods')
      Rails.root.join('files', 'cosmosys', 'templates', kind.to_s, 'sources')
    end

    def source_path
      self.class.storage_root(kind).join(storage_key)
    end

    def in_use?
      ods_overriding_projects.exists? || report_overriding_projects.exists?
    end

    def remove_file!
      File.delete(source_path) if source_path.file?
    end
  end
end
