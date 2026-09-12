RedmineApp::Application.routes.draw do
  resources :cosmosys_catalog_refs,
            path: 'cosmosys/document-references',
            controller: 'cosmosys/catalog_refs',
            only: [:show, :edit, :update, :destroy]
  post 'issues/:issue_id/cosmosys/document-references', to: 'cosmosys/catalog_refs#create', as: :issue_cosmosys_catalog_refs
  match 'issues/:issue_id/cosmosys/split', to: 'cosmosys/item_operations#split', via: [:get, :post], as: :issue_cosmosys_split
  match 'issues/:issue_id/cosmosys/related-items', to: 'cosmosys/item_operations#related', via: [:get, :post], as: :issue_cosmosys_related_items
  get 'projects/:project_id/cosmosys/document-catalog', to: 'cosmosys/document_catalog_entries#index', as: :project_cosmosys_document_catalog
  post 'projects/:project_id/cosmosys/document-catalog/report-placeholders', to: 'cosmosys/document_catalog_entries#create_report_placeholders', as: :project_cosmosys_document_catalog_report_placeholders
  match 'projects/:project_id/cosmosys/document-catalog/:id',
        to: 'cosmosys/document_catalog_entries#show',
        via: :get,
        as: :project_cosmosys_document_catalog_entry
  patch 'projects/:project_id/cosmosys/document-catalog/:id', to: 'cosmosys/document_catalog_entries#update'

  get 'admin/cosmosys/item-kinds', to: 'cosmosys/item_kinds#index', as: :cosmosys_item_kinds
  put 'admin/cosmosys/item-kinds', to: 'cosmosys/item_kinds#update'
  resources :cosmosys_template_assets,
            path: 'admin/cosmosys/templates',
            controller: 'cosmosys/template_assets',
            only: [:index, :create, :destroy]

  scope ':project_id', constraints: { project_id: /[^\/]+/ } do
    get 'cosmosys', to: 'cosmosys/items#index'
    get 'cosmosys/overview', to: 'cosmosys/items#overview'
    get 'cosmosys/report', to: 'cosmosys/items#report'
    get 'cosmosys/report/diagram/:kind/:issue_id', to: 'cosmosys/items#report_diagram', as: :cosmosys_report_diagram
    post 'cosmosys/report/export', to: 'cosmosys/items#report_export', as: :cosmosys_report_export
    post 'cosmosys/export/ods', to: 'cosmosys/items#ods_export', as: :cosmosys_ods_export
    get 'cosmosys/transfers', to: 'cosmosys/ods_transfers#index', as: :project_cosmosys_ods_transfers
    get 'cosmosys/import/ods', to: 'cosmosys/ods_transfers#new', as: :new_project_cosmosys_ods_transfer
    post 'cosmosys/import/ods', to: 'cosmosys/ods_transfers#create', as: :project_cosmosys_ods_transfer_upload
    get 'cosmosys/materialize/ods', to: 'cosmosys/ods_transfers#new_materialization', as: :new_project_cosmosys_ods_materialization
    post 'cosmosys/materialize/ods', to: 'cosmosys/ods_transfers#create_materialization', as: :project_cosmosys_ods_materialization
    get 'cosmosys/transfers/:id', to: 'cosmosys/ods_transfers#show', as: :project_cosmosys_ods_transfer
    get 'cosmosys/transfers/:id/status', to: 'cosmosys/ods_transfers#status', as: :status_project_cosmosys_ods_transfer
    post 'cosmosys/transfers/:id/apply', to: 'cosmosys/ods_transfers#apply', as: :apply_project_cosmosys_ods_transfer
    post 'cosmosys/transfers/:id/materialize', to: 'cosmosys/ods_transfers#materialize', as: :materialize_project_cosmosys_ods_transfer
    get 'cosmosys/transfers/:id/reconciled', to: 'cosmosys/ods_transfers#download', as: :download_project_cosmosys_ods_transfer
    get 'cosmosys/snapshots', to: 'cosmosys/project_snapshots#index', as: :project_cosmosys_snapshots
    post 'cosmosys/snapshots', to: 'cosmosys/project_snapshots#create'
    get 'cosmosys/snapshots/import', to: 'cosmosys/project_snapshots#new_import', as: :new_import_project_cosmosys_snapshot
    post 'cosmosys/snapshots/import', to: 'cosmosys/project_snapshots#import', as: :import_project_cosmosys_snapshot
    get 'cosmosys/snapshots/:id', to: 'cosmosys/project_snapshots#show', as: :project_cosmosys_snapshot
    get 'cosmosys/snapshots/:id/download', to: 'cosmosys/project_snapshots#download', as: :download_project_cosmosys_snapshot
    get 'cosmosys/snapshots/:id/materialize', to: 'cosmosys/project_snapshots#new_materialization', as: :materialize_project_cosmosys_snapshot
    post 'cosmosys/snapshots/:id/materialize', to: 'cosmosys/project_snapshots#materialize'
    delete 'cosmosys/snapshots/:id', to: 'cosmosys/project_snapshots#destroy'
    get 'cosmosys/templates/profile', to: 'cosmosys/project_templates#profile', as: :project_cosmosys_profile_template
    get 'cosmosys/templates/effective', to: 'cosmosys/project_templates#effective', as: :project_cosmosys_effective_template
    get 'cosmosys/templates/report/profile', to: 'cosmosys/project_templates#report_profile', as: :project_cosmosys_profile_report_template
    get 'cosmosys/templates/report/effective', to: 'cosmosys/project_templates#report_effective', as: :project_cosmosys_effective_report_template
    put 'cosmosys/settings', to: 'cosmosys/project_settings#update', as: :project_cosmosys_settings
    get 'cosmosys/tree', to: 'cosmosys/items#tree'
    get 'cosmosys/dsm', to: 'cosmosys/items#dsm', as: :project_cosmosys_dsm
    get 'cosmosys/diagram_panel/:kind', to: 'cosmosys/items#diagram_panel', as: :cosmosys_diagram_panel
    get 'cosmosys/diagrams/:kind/:diagram_format', to: 'cosmosys/items#diagram_export', as: :cosmosys_diagram_export
    get 'cosmosys/tree/details/:issue_id', to: 'cosmosys/items#details', as: :cosmosys_tree_details
    get 'cosmosys/items/:csid', to: 'cosmosys/items#resolve', as: :cosmosys_item_by_csid, constraints: { csid: /[A-Za-z0-9]+-[0-9]+/ }
    post 'cosmosys/tree/move', to: 'cosmosys/items#move'
    post 'cosmosys/tree/rebuild', to: 'cosmosys/items#rebuild_tree'
  end
end
