require 'set'

class CreateCosmosysBootstrap < ActiveRecord::Migration[6.1]
  class ProjectRecord < ActiveRecord::Base
    self.table_name = 'projects'
  end

  class IssueRecord < ActiveRecord::Base
    self.table_name = 'issues'
  end

  def up
    add_column :issue_relations, :cosmosys_restricted, :boolean, null: false, default: false unless column_exists?(:issue_relations, :cosmosys_restricted)
    add_column :trackers, :cosmosys_key, :string unless column_exists?(:trackers, :cosmosys_key)
    add_column :trackers, :cosmosys_item_kind, :string, null: false, default: 'normal' unless column_exists?(:trackers, :cosmosys_item_kind)
    add_index :trackers, :cosmosys_key, unique: true, where: 'cosmosys_key IS NOT NULL' unless index_exists?(:trackers, :cosmosys_key)
    add_index :trackers, :cosmosys_item_kind unless index_exists?(:trackers, :cosmosys_item_kind)

    add_column :projects, :cscode, :string unless column_exists?(:projects, :cscode)
    add_column :projects, :cslast_id, :integer, null: false, default: 0 unless column_exists?(:projects, :cslast_id)
    add_column :projects, :cosmosys_project_profile, :string, null: false, default: 'items' unless column_exists?(:projects, :cosmosys_project_profile)
    add_column :projects, :cosmosys_root_tracker_key, :string unless column_exists?(:projects, :cosmosys_root_tracker_key)
    add_column :projects, :cosmosys_ods_template_asset_id, :integer unless column_exists?(:projects, :cosmosys_ods_template_asset_id)
    add_column :projects, :cosmosys_report_template_asset_id, :integer unless column_exists?(:projects, :cosmosys_report_template_asset_id)
    add_column :projects, :cosmosys_report_template_key, :string unless column_exists?(:projects, :cosmosys_report_template_key)
    add_column :projects, :cosmosys_project_passphrase, :string unless column_exists?(:projects, :cosmosys_project_passphrase)
    add_column :projects, :cosmosys_language, :string unless column_exists?(:projects, :cosmosys_language)

    add_index :projects, :cscode unless index_exists?(:projects, :cscode)
    add_index :projects, 'LOWER(cscode)', name: 'idx_projects_lower_cscode' unless index_exists?(:projects, name: 'idx_projects_lower_cscode')

    unless table_exists?(:cosmosys_template_assets)
      create_table :cosmosys_template_assets do |t|
        t.string :name, null: false
        t.string :kind, null: false, default: 'ods'
        t.string :storage_key, null: false
        t.string :original_filename, null: false
        t.string :sha256, null: false
        t.integer :byte_size, null: false
        t.integer :created_by_id, null: false
        t.boolean :active, null: false, default: true
        t.timestamps null: false
      end
    end
    add_index :cosmosys_template_assets, :storage_key, unique: true unless index_exists?(:cosmosys_template_assets, :storage_key, unique: true)
    add_index :cosmosys_template_assets, [:kind, :active, :name], name: 'idx_cosmosys_template_assets_catalog' unless index_exists?(:cosmosys_template_assets, [:kind, :active, :name], name: 'idx_cosmosys_template_assets_catalog')
    add_foreign_key :projects, :cosmosys_template_assets, column: :cosmosys_ods_template_asset_id, name: 'fk_projects_cosmosys_ods_template' unless foreign_key_exists?(:projects, :cosmosys_template_assets, column: :cosmosys_ods_template_asset_id, name: 'fk_projects_cosmosys_ods_template')
    add_foreign_key :projects, :cosmosys_template_assets, column: :cosmosys_report_template_asset_id, name: 'fk_projects_cosmosys_report_template' unless foreign_key_exists?(:projects, :cosmosys_template_assets, column: :cosmosys_report_template_asset_id, name: 'fk_projects_cosmosys_report_template')

    add_column :issues, :csid, :string unless column_exists?(:issues, :csid)
    add_column :issues, :csidnum, :integer unless column_exists?(:issues, :csidnum)
    add_column :issues, :csposition, :integer unless column_exists?(:issues, :csposition)
    add_column :issues, :cosmosys_preferred_report_diagram, :string,
               null: false, default: 'combined' unless column_exists?(:issues, :cosmosys_preferred_report_diagram)

    add_index :issues, :csid unless index_exists?(:issues, :csid)
    add_index :issues, 'LOWER(csid)', name: 'idx_issues_lower_csid' unless index_exists?(:issues, name: 'idx_issues_lower_csid')
    add_index :issues, :csidnum unless index_exists?(:issues, :csidnum)
    add_index :issues, [:parent_id, :csposition] unless index_exists?(:issues, [:parent_id, :csposition])

    add_column :documents, :external_code, :string unless column_exists?(:documents, :external_code)
    add_column :documents, :cosmosys_document_date, :date unless column_exists?(:documents, :cosmosys_document_date)
    add_column :documents, :cosmosys_document_version, :string unless column_exists?(:documents, :cosmosys_document_version)
    add_index :documents, [:project_id, :external_code], name: 'idx_documents_project_external_code' unless index_exists?(:documents, [:project_id, :external_code], name: 'idx_documents_project_external_code')

    unless table_exists?(:cosmosys_document_catalog_entries)
      create_table :cosmosys_document_catalog_entries do |t|
        t.integer :project_id, null: false
        t.integer :document_id, null: false
        t.string :family, null: false, limit: 1
        t.integer :position, null: false
        t.timestamps null: false
      end
    end
    add_index :cosmosys_document_catalog_entries, [:project_id, :family, :position], name: 'idx_cosmosys_doc_entries_order' unless index_exists?(:cosmosys_document_catalog_entries, [:project_id, :family, :position], name: 'idx_cosmosys_doc_entries_order')
    add_index :cosmosys_document_catalog_entries, [:document_id, :family], unique: true, name: 'idx_cosmosys_doc_entries_document_family' unless index_exists?(:cosmosys_document_catalog_entries, [:document_id, :family], unique: true, name: 'idx_cosmosys_doc_entries_document_family')
    add_foreign_key :cosmosys_document_catalog_entries, :documents, column: :document_id unless foreign_key_exists?(:cosmosys_document_catalog_entries, :documents, column: :document_id)

    unless table_exists?(:cosmosys_catalog_refs)
      create_table :cosmosys_catalog_refs do |t|
        t.integer :document_catalog_entry_id, null: false
        t.integer :issue_id, null: false
        t.string :sense, limit: 255
        t.string :location, limit: 255
        t.timestamps null: false
      end
    end
    add_index :cosmosys_catalog_refs, :issue_id unless index_exists?(:cosmosys_catalog_refs, :issue_id)
    add_index :cosmosys_catalog_refs, :document_catalog_entry_id, name: 'idx_cosmosys_catalog_refs_entry' unless index_exists?(:cosmosys_catalog_refs, :document_catalog_entry_id, name: 'idx_cosmosys_catalog_refs_entry')
    add_foreign_key :cosmosys_catalog_refs, :issues, column: :issue_id unless foreign_key_exists?(:cosmosys_catalog_refs, :issues, column: :issue_id)
    add_foreign_key :cosmosys_catalog_refs, :cosmosys_document_catalog_entries, column: :document_catalog_entry_id, name: 'fk_cosmosys_catalog_refs_entry' unless foreign_key_exists?(:cosmosys_catalog_refs, :cosmosys_document_catalog_entries, column: :document_catalog_entry_id, name: 'fk_cosmosys_catalog_refs_entry')

    unless table_exists?(:cosmosys_report_placeholders)
      create_table :cosmosys_report_placeholders do |t|
        t.integer :issue_id, null: false
        t.integer :project_id, null: false
        t.string :kind, null: false
        t.timestamps null: false
      end
    end
    add_index :cosmosys_report_placeholders, :issue_id, unique: true unless index_exists?(:cosmosys_report_placeholders, :issue_id, unique: true)
    add_index :cosmosys_report_placeholders, [:project_id, :kind], unique: true, name: 'idx_cosmosys_report_placeholders_scope' unless index_exists?(:cosmosys_report_placeholders, [:project_id, :kind], unique: true, name: 'idx_cosmosys_report_placeholders_scope')
    add_foreign_key :cosmosys_report_placeholders, :issues, column: :issue_id unless foreign_key_exists?(:cosmosys_report_placeholders, :issues, column: :issue_id)

    unless table_exists?(:cosmosys_diagrams)
      create_table :cosmosys_diagrams do |t|
        t.integer :issue_id
        t.integer :project_id
        t.string :kind, null: false
        t.string :render_variant, null: false, default: ''
        t.string :layout_mode, null: false, default: ''
        t.string :state, null: false, default: 'obsolete'
        t.integer :root_generation, null: false, default: 0
        t.integer :tree_revision, null: false, default: 0
        t.string :signature
        t.text :svg_body
        t.text :dot_body
        t.datetime :generated_at
        t.timestamps null: false
      end
    end

    add_column :cosmosys_diagrams, :render_variant, :string, null: false, default: '' unless column_exists?(:cosmosys_diagrams, :render_variant)
    add_column :cosmosys_diagrams, :layout_mode, :string, null: false, default: '' unless column_exists?(:cosmosys_diagrams, :layout_mode)

    remove_index :cosmosys_diagrams, name: 'idx_cosmosys_diagrams_issue_kind' if index_exists?(:cosmosys_diagrams, name: 'idx_cosmosys_diagrams_issue_kind')
    remove_index :cosmosys_diagrams, name: 'idx_cosmosys_diagrams_project_kind' if index_exists?(:cosmosys_diagrams, name: 'idx_cosmosys_diagrams_project_kind')
    add_index :cosmosys_diagrams, [:issue_id, :kind, :render_variant, :layout_mode], unique: true, where: 'issue_id IS NOT NULL', name: 'idx_cosmosys_diagrams_issue_render_kind' unless index_exists?(:cosmosys_diagrams, [:issue_id, :kind, :render_variant, :layout_mode], unique: true, where: 'issue_id IS NOT NULL', name: 'idx_cosmosys_diagrams_issue_render_kind')
    add_index :cosmosys_diagrams, [:project_id, :kind, :render_variant, :layout_mode], unique: true, where: 'project_id IS NOT NULL', name: 'idx_cosmosys_diagrams_project_render_kind' unless index_exists?(:cosmosys_diagrams, [:project_id, :kind, :render_variant, :layout_mode], unique: true, where: 'project_id IS NOT NULL', name: 'idx_cosmosys_diagrams_project_render_kind')

    unless table_exists?(:cosmosys_issue_tree_revisions)
      create_table :cosmosys_issue_tree_revisions do |t|
        t.integer :root_issue_id, null: false
        t.boolean :active, null: false, default: true
        t.integer :root_generation, null: false, default: 0
        t.integer :revision, null: false, default: 0
        t.timestamps null: false
      end
    end

    add_index :cosmosys_issue_tree_revisions, :root_issue_id, unique: true unless index_exists?(:cosmosys_issue_tree_revisions, :root_issue_id, unique: true)

    unless table_exists?(:cosmosys_project_report_settings)
      create_table :cosmosys_project_report_settings do |t|
        t.integer :project_id, null: false
        t.text :column_names
        t.timestamps null: false
      end
    end

    add_index :cosmosys_project_report_settings, :project_id, unique: true unless index_exists?(:cosmosys_project_report_settings, :project_id, unique: true)

    unless table_exists?(:cosmosys_diagram_preferences)
      create_table :cosmosys_diagram_preferences do |t|
        t.integer :updated_by_id
        t.integer :issue_id
        t.integer :project_id
        t.string :kind, null: false
        t.string :render_variant, null: false, default: ''
        t.string :layout_mode, null: false, default: ''
        t.text :visible_layers
        t.timestamps null: false
      end
    end

    add_column :cosmosys_diagram_preferences, :visible_layers, :text unless column_exists?(:cosmosys_diagram_preferences, :visible_layers)

    add_index :cosmosys_diagram_preferences, [:issue_id, :kind], unique: true, where: 'issue_id IS NOT NULL', name: 'idx_cosmosys_diagram_preferences_issue_kind' unless index_exists?(:cosmosys_diagram_preferences, [:issue_id, :kind], unique: true, where: 'issue_id IS NOT NULL', name: 'idx_cosmosys_diagram_preferences_issue_kind')
    add_index :cosmosys_diagram_preferences, [:project_id, :kind], unique: true, where: 'project_id IS NOT NULL', name: 'idx_cosmosys_diagram_preferences_project_kind' unless index_exists?(:cosmosys_diagram_preferences, [:project_id, :kind], unique: true, where: 'project_id IS NOT NULL', name: 'idx_cosmosys_diagram_preferences_project_kind')

    unless table_exists?(:cosmosys_ods_transfers)
      create_table :cosmosys_ods_transfers do |t|
        t.integer :project_id, null: false
        t.integer :user_id, null: false
        t.string :direction, null: false
        t.string :state, null: false
        t.string :original_filename
        t.string :content_type
        t.integer :byte_size, null: false, default: 0
        t.string :file_sha256
        t.string :payload_sha256
        t.string :export_id
        t.string :format_version
        t.boolean :include_subprojects, null: false, default: false
        t.text :summary_json
        t.binary :file_data
        t.binary :result_data
        t.timestamps null: false
      end
    end
    add_index :cosmosys_ods_transfers, [:project_id, :direction, :created_at], name: 'idx_cosmosys_ods_transfers_history' unless index_exists?(:cosmosys_ods_transfers, [:project_id, :direction, :created_at], name: 'idx_cosmosys_ods_transfers_history')
    add_index :cosmosys_ods_transfers, [:project_id, :payload_sha256], name: 'idx_cosmosys_ods_transfers_payload' unless index_exists?(:cosmosys_ods_transfers, [:project_id, :payload_sha256], name: 'idx_cosmosys_ods_transfers_payload')
    add_index :cosmosys_ods_transfers, :export_id unless index_exists?(:cosmosys_ods_transfers, :export_id)

    unless table_exists?(:cosmosys_ods_transfer_events)
      create_table :cosmosys_ods_transfer_events do |t|
        t.integer :ods_transfer_id, null: false
        t.string :severity, null: false
        t.string :code, null: false
        t.string :sheet
        t.integer :row_number
        t.string :field_name
        t.string :entity_type
        t.string :entity_key
        t.text :message
        t.text :details_json
        t.timestamps null: false
      end
    end
    add_index :cosmosys_ods_transfer_events, [:ods_transfer_id, :severity], name: 'idx_cosmosys_ods_events_transfer' unless index_exists?(:cosmosys_ods_transfer_events, [:ods_transfer_id, :severity], name: 'idx_cosmosys_ods_events_transfer')
    add_foreign_key :cosmosys_ods_transfer_events, :cosmosys_ods_transfers, column: :ods_transfer_id, name: 'fk_cosmosys_ods_events_transfer' unless foreign_key_exists?(:cosmosys_ods_transfer_events, :cosmosys_ods_transfers, column: :ods_transfer_id, name: 'fk_cosmosys_ods_events_transfer')

    unless table_exists?(:cosmosys_ods_import_identities)
      create_table :cosmosys_ods_import_identities do |t|
        t.integer :project_id, null: false
        t.string :export_id, null: false
        t.string :row_uuid, null: false
        t.string :entity_type, null: false
        t.integer :entity_id, null: false
        t.timestamps null: false
      end
    end
    add_index :cosmosys_ods_import_identities, [:project_id, :export_id, :row_uuid], unique: true, name: 'idx_cosmosys_ods_import_identity' unless index_exists?(:cosmosys_ods_import_identities, [:project_id, :export_id, :row_uuid], unique: true, name: 'idx_cosmosys_ods_import_identity')

    install_structural_trackers
    backfill_existing_cosmosys_data
    configure_redmine_defaults
  end

  def down
    remove_column :issue_relations, :cosmosys_restricted if column_exists?(:issue_relations, :cosmosys_restricted)
    remove_foreign_key :projects, name: 'fk_projects_cosmosys_ods_template' if foreign_key_exists?(:projects, name: 'fk_projects_cosmosys_ods_template')
    remove_foreign_key :projects, name: 'fk_projects_cosmosys_report_template' if foreign_key_exists?(:projects, name: 'fk_projects_cosmosys_report_template')
    remove_index :cosmosys_template_assets, name: 'idx_cosmosys_template_assets_catalog' if index_exists?(:cosmosys_template_assets, name: 'idx_cosmosys_template_assets_catalog')
    remove_index :cosmosys_template_assets, :storage_key if index_exists?(:cosmosys_template_assets, :storage_key)
    drop_table :cosmosys_template_assets if table_exists?(:cosmosys_template_assets)
    remove_index :cosmosys_ods_import_identities, name: 'idx_cosmosys_ods_import_identity' if index_exists?(:cosmosys_ods_import_identities, name: 'idx_cosmosys_ods_import_identity')
    drop_table :cosmosys_ods_import_identities if table_exists?(:cosmosys_ods_import_identities)
    remove_index :cosmosys_ods_transfer_events, name: 'idx_cosmosys_ods_events_transfer' if index_exists?(:cosmosys_ods_transfer_events, name: 'idx_cosmosys_ods_events_transfer')
    drop_table :cosmosys_ods_transfer_events if table_exists?(:cosmosys_ods_transfer_events)
    remove_index :cosmosys_ods_transfers, :export_id if index_exists?(:cosmosys_ods_transfers, :export_id)
    remove_index :cosmosys_ods_transfers, name: 'idx_cosmosys_ods_transfers_payload' if index_exists?(:cosmosys_ods_transfers, name: 'idx_cosmosys_ods_transfers_payload')
    remove_index :cosmosys_ods_transfers, name: 'idx_cosmosys_ods_transfers_history' if index_exists?(:cosmosys_ods_transfers, name: 'idx_cosmosys_ods_transfers_history')
    drop_table :cosmosys_ods_transfers if table_exists?(:cosmosys_ods_transfers)

    remove_index :cosmosys_report_placeholders, name: 'idx_cosmosys_report_placeholders_scope' if index_exists?(:cosmosys_report_placeholders, name: 'idx_cosmosys_report_placeholders_scope')
    remove_index :cosmosys_report_placeholders, :issue_id if index_exists?(:cosmosys_report_placeholders, :issue_id)
    drop_table :cosmosys_report_placeholders if table_exists?(:cosmosys_report_placeholders)

    remove_index :cosmosys_catalog_refs, name: 'idx_cosmosys_catalog_refs_entry' if index_exists?(:cosmosys_catalog_refs, name: 'idx_cosmosys_catalog_refs_entry')
    remove_index :cosmosys_catalog_refs, :issue_id if index_exists?(:cosmosys_catalog_refs, :issue_id)
    drop_table :cosmosys_catalog_refs if table_exists?(:cosmosys_catalog_refs)

    remove_index :cosmosys_document_catalog_entries, name: 'idx_cosmosys_doc_entries_document_family' if index_exists?(:cosmosys_document_catalog_entries, name: 'idx_cosmosys_doc_entries_document_family')
    remove_index :cosmosys_document_catalog_entries, name: 'idx_cosmosys_doc_entries_order' if index_exists?(:cosmosys_document_catalog_entries, name: 'idx_cosmosys_doc_entries_order')
    drop_table :cosmosys_document_catalog_entries if table_exists?(:cosmosys_document_catalog_entries)

    remove_index :documents, name: 'idx_documents_project_external_code' if index_exists?(:documents, name: 'idx_documents_project_external_code')
    remove_column :documents, :cosmosys_document_version if column_exists?(:documents, :cosmosys_document_version)
    remove_column :documents, :cosmosys_document_date if column_exists?(:documents, :cosmosys_document_date)
    remove_column :documents, :external_code if column_exists?(:documents, :external_code)

    remove_column :projects, :cosmosys_project_profile if column_exists?(:projects, :cosmosys_project_profile)
    remove_column :projects, :cosmosys_root_tracker_key if column_exists?(:projects, :cosmosys_root_tracker_key)
    remove_column :projects, :cosmosys_ods_template_asset_id if column_exists?(:projects, :cosmosys_ods_template_asset_id)
    remove_column :projects, :cosmosys_report_template_asset_id if column_exists?(:projects, :cosmosys_report_template_asset_id)
    remove_column :projects, :cosmosys_report_template_key if column_exists?(:projects, :cosmosys_report_template_key)
    remove_column :projects, :cosmosys_project_passphrase if column_exists?(:projects, :cosmosys_project_passphrase)
    remove_column :projects, :cosmosys_language if column_exists?(:projects, :cosmosys_language)
    remove_index :trackers, :cosmosys_key if index_exists?(:trackers, :cosmosys_key)
    remove_column :trackers, :cosmosys_key if column_exists?(:trackers, :cosmosys_key)
    remove_index :trackers, :cosmosys_item_kind if index_exists?(:trackers, :cosmosys_item_kind)
    remove_column :trackers, :cosmosys_item_kind if column_exists?(:trackers, :cosmosys_item_kind)

    remove_index :cosmosys_project_report_settings, :project_id if index_exists?(:cosmosys_project_report_settings, :project_id, unique: true)
    drop_table :cosmosys_project_report_settings if table_exists?(:cosmosys_project_report_settings)

    remove_index :cosmosys_diagram_preferences, name: 'idx_cosmosys_diagram_preferences_project_kind' if index_exists?(:cosmosys_diagram_preferences, name: 'idx_cosmosys_diagram_preferences_project_kind')
    remove_index :cosmosys_diagram_preferences, name: 'idx_cosmosys_diagram_preferences_issue_kind' if index_exists?(:cosmosys_diagram_preferences, name: 'idx_cosmosys_diagram_preferences_issue_kind')
    drop_table :cosmosys_diagram_preferences if table_exists?(:cosmosys_diagram_preferences)

    remove_index :cosmosys_issue_tree_revisions, :root_issue_id if index_exists?(:cosmosys_issue_tree_revisions, :root_issue_id, unique: true)
    drop_table :cosmosys_issue_tree_revisions if table_exists?(:cosmosys_issue_tree_revisions)

    remove_index :cosmosys_diagrams, name: 'idx_cosmosys_diagrams_project_render_kind' if index_exists?(:cosmosys_diagrams, name: 'idx_cosmosys_diagrams_project_render_kind')
    remove_index :cosmosys_diagrams, name: 'idx_cosmosys_diagrams_issue_render_kind' if index_exists?(:cosmosys_diagrams, name: 'idx_cosmosys_diagrams_issue_render_kind')
    drop_table :cosmosys_diagrams if table_exists?(:cosmosys_diagrams)

    remove_index :issues, column: [:parent_id, :csposition] if index_exists?(:issues, [:parent_id, :csposition])
    remove_index :issues, :csidnum if index_exists?(:issues, :csidnum)
    remove_index :issues, name: 'idx_issues_lower_csid' if index_exists?(:issues, name: 'idx_issues_lower_csid')
    remove_index :issues, :csid if index_exists?(:issues, :csid)
    remove_column :issues, :cosmosys_preferred_report_diagram if column_exists?(:issues, :cosmosys_preferred_report_diagram)
    remove_column :issues, :csposition if column_exists?(:issues, :csposition)
    remove_column :issues, :csidnum if column_exists?(:issues, :csidnum)
    remove_column :issues, :csid if column_exists?(:issues, :csid)

    remove_index :projects, name: 'idx_projects_lower_cscode' if index_exists?(:projects, name: 'idx_projects_lower_cscode')
    remove_index :projects, :cscode if index_exists?(:projects, :cscode)
    remove_column :projects, :cslast_id if column_exists?(:projects, :cslast_id)
    remove_column :projects, :cscode if column_exists?(:projects, :cscode)
  end

  private

  def install_structural_trackers
    tracker_class = Class.new(ActiveRecord::Base) { self.table_name = 'trackers' }
    tracker_class.reset_column_information
    status_id = select_value('SELECT id FROM issue_statuses ORDER BY position, id LIMIT 1')
    raise 'cosmoSys requires at least one Redmine item status' if status_id.blank?

    {
      'cs_info' => { name: 'csInfo', item_profile: 'info' },
      'cs_ref_doc' => { name: 'csRefDoc', item_profile: 'doc' }
    }.each do |key, definition|
      tracker = tracker_class.find_by(cosmosys_key: key) ||
                tracker_class.where('LOWER(name) = ?', definition.fetch(:name).downcase).order(:id).first ||
                tracker_class.new
      tracker.assign_attributes(name: definition.fetch(:name), cosmosys_key: key, cosmosys_item_kind: definition.fetch(:item_profile), default_status_id: status_id)
      tracker.save!
      reset_feature_workflow(tracker.id)
      execute "INSERT INTO projects_trackers (project_id, tracker_id) SELECT id, #{tracker.id} FROM projects ON CONFLICT DO NOTHING"
    end
  end

  def reset_feature_workflow(tracker_id)
    return unless table_exists?(:workflows)

    feature_id = select_value("SELECT id FROM trackers WHERE LOWER(name) = 'feature' ORDER BY id LIMIT 1")
    return if feature_id.blank? || feature_id.to_i == tracker_id.to_i

    workflow_columns = columns(:workflows).map(&:name) - %w[id tracker_id]
    quoted_columns = workflow_columns.map { |column| connection.quote_column_name(column) }
    execute "DELETE FROM workflows WHERE tracker_id = #{tracker_id}"
    execute <<~SQL.squish
      INSERT INTO workflows (tracker_id, #{quoted_columns.join(', ')})
      SELECT #{tracker_id}, #{quoted_columns.join(', ')}
      FROM workflows
      WHERE tracker_id = #{feature_id}
    SQL
  end

  def backfill_existing_cosmosys_data
    ProjectRecord.reset_column_information
    IssueRecord.reset_column_information

    backfill_project_codes
    backfill_issue_identifiers
  end

  def backfill_project_codes
    projects = ProjectRecord.select(:id, :identifier, :parent_id, :lft, :rgt).order(:lft, :id).to_a
    projects_by_id = projects.index_by(&:id)
    root_id_by_project_id = {}
    used_codes_by_root_id = Hash.new { |hash, key| hash[key] = Set.new }

    projects.each do |project|
      root_id = project_root_id(project, projects_by_id, root_id_by_project_id)
      cscode = unique_project_code(project, root_id, used_codes_by_root_id)
      ProjectRecord.where(id: project.id).update_all(cscode: cscode, cslast_id: 0)
    end
  end

  def backfill_issue_identifiers
    issues = IssueRecord.select(:id, :project_id, :parent_id, :root_id, :lft, :rgt).order(:root_id, :lft, :id).to_a
    return if issues.empty?

    issues_by_id = issues.index_by(&:id)
    issues_by_project = issues.group_by(&:project_id)
    issues_by_parent = issues.group_by(&:parent_id)

    issues.each do |issue|
      csidnum = next_issue_sequence_for(issue, issues_by_project)
      csposition = position_for(issue, issues_by_parent)
      project = ProjectRecord.find(issue.project_id)
      csid = format('%s-%04d', project.cscode, csidnum)

      IssueRecord.where(id: issue.id).update_all(
        csid: csid,
        csidnum: csidnum,
        csposition: csposition
      )
    end

    issues_by_project.each do |project_id, project_issues|
      ProjectRecord.where(id: project_id).update_all(cslast_id: project_issues.size)
    end
  end

  def next_issue_sequence_for(issue, issues_by_project)
    project_issues = issues_by_project.fetch(issue.project_id)
    @issue_sequence_by_project ||= {}
    @issue_sequence_by_project[issue.project_id] ||= {}
    existing = @issue_sequence_by_project[issue.project_id]
    existing[issue.id] = existing.size + 1
    existing[issue.id]
  end

  def position_for(issue, issues_by_parent)
    siblings =
      if issue.parent_id.present?
        Array(issues_by_parent[issue.parent_id])
      else
        Array(issues_by_parent[nil]).select { |candidate| candidate.project_id == issue.project_id }
      end

    siblings.sort_by! { |candidate| [candidate.lft || 0, candidate.id] }
    siblings.index { |candidate| candidate.id == issue.id }.to_i + 1
  end

  def project_root_id(project, projects_by_id, root_id_by_project_id)
    return root_id_by_project_id[project.id] if root_id_by_project_id.key?(project.id)

    root_id =
      if project.parent_id.present?
        parent = projects_by_id.fetch(project.parent_id)
        project_root_id(parent, projects_by_id, root_id_by_project_id)
      else
        project.id
      end

    root_id_by_project_id[project.id] = root_id
  end

  def unique_project_code(project, root_id, used_codes_by_root_id)
    used_codes = used_codes_by_root_id[root_id]
    base_code = normalize_project_code(project.identifier)
    candidate = base_code

    if candidate.blank? || used_codes.include?(candidate)
      candidate = "#{base_code.presence || 'P'}#{project.id}"
    end

    while used_codes.include?(candidate)
      candidate = "#{candidate}X"
    end

    used_codes << candidate
    candidate
  end

  def normalize_project_code(identifier)
    identifier.to_s.gsub(/[^a-zA-Z0-9]/, '').presence
  end

  def configure_redmine_defaults
    Setting[:cross_project_issue_relations] = '1'
    Setting[:cross_project_subtasks] = 'hierarchy'
    Setting[:close_duplicate_issues] = '0'
    Setting[:issue_group_assignment] = '1'
    Setting[:default_projects_public] = '0'
    Setting[:rest_api_enabled] = '1'
    Setting[:jsonp_enabled] = '1'
    Setting[:project_list_display_type] = 'list'

    # cosmoSys is instance-wide. It is deliberately not represented as an
    # enabled project module, so projects cannot disable only part of its
    # structural contract.
    Setting[:default_projects_modules] = Array(Setting[:default_projects_modules]).map(&:to_s) - ['cosmosys']
    execute "DELETE FROM enabled_modules WHERE name = 'cosmosys'" if table_exists?(:enabled_modules)

    project_list_defaults = (Setting[:project_list_defaults] || {}).deep_stringify_keys
    project_columns = Array(project_list_defaults['column_names']).map(&:to_s)
    Setting[:project_list_defaults] = project_list_defaults.merge(
      'column_names' => project_columns | %w[name identifier short_description]
    )

    issue_columns = Array(Setting[:issue_list_default_columns]).map(&:to_s)
    default_issue_columns = %w[tracker status priority subject assigned_to updated_on category fixed_version]
    Setting[:issue_list_default_columns] = issue_columns | default_issue_columns
  end
end
