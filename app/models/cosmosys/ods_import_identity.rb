module Cosmosys
  class OdsImportIdentity < ActiveRecord::Base
    self.table_name = 'cosmosys_ods_import_identities'

    belongs_to :project

    validates :export_id, :row_uuid, :entity_type, :entity_id, presence: true
    validates :row_uuid, uniqueness: { scope: [:project_id, :export_id] }
  end
end
