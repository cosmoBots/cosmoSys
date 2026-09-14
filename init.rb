require 'redmine'
require 'i18n/backend/fallbacks'

I18n::Backend::Simple.include(I18n::Backend::Fallbacks) unless I18n::Backend::Simple < I18n::Backend::Fallbacks
I18n.fallbacks.defaults = [:en]

Rails.application.config.filter_parameters += [:html, :instance_passphrase, :project_passphrase]

Redmine::Plugin.register :cosmosys do
  name 'cosmoSys'
  author 'cosmoBots.eu'
  description 'Base plugin for cosmoSys on top of Redmine.'
  version '0.1.1-dev'
  url 'https://github.com/cosmoBots/cosmoSys'
  author_url 'https://cosmobots.eu'

  menu :project_menu, :cosmosys, { controller: 'cosmosys/items', action: 'tree' },
    caption: 'cosmoSys',
    param: :project_id,
    permission: false,
    if: proc { |project| project&.visible?(User.current) }

  menu :admin_menu, :cosmosys_item_kinds, { controller: 'cosmosys/item_kinds', action: 'index' },
    caption: :label_cosmosys_item_kinds,
    icon: 'bookmarked',
    html: { class: 'icon icon-fav' }

  menu :admin_menu, :cosmosys_template_assets, { controller: 'cosmosys/template_assets', action: 'index' },
    caption: :label_cosmosys_template_assets,
    icon: 'file',
    html: { class: 'icon icon-file' }

  settings default: {
    'precedes_direction' => 'forward',
    'instance_passphrase' => 'admin',
    'invalidate_diagram_cache_on_boot' => '0',
    'official_project_language' => 'en',
    'report_export_format' => 'odt',
    'main_report_default_columns' => [],
    'main_report_field_presentations' => {},
    'main_report_options' => {
      'description' => '1',
      'preferred_diagram' => '1',
      'combined_diagram' => '0',
      'hierarchy_diagram' => '0',
      'dependency_diagram' => '0'
    }
  }, partial: 'settings/cosmosys_settings'
end

require_dependency 'project'
require_dependency 'issue'
require_dependency 'issue_relation'
require_dependency 'document'
require_dependency 'tracker'
require_dependency 'issue_status'
require_dependency 'project_query'
require_dependency 'issue_query'
require_dependency 'application_helper'
require_dependency 'auto_completes_controller'
require_dependency 'issue_relations_controller'
require_dependency 'issues_helper'
require_dependency 'issues_controller'
require_dependency 'documents_controller'
require_dependency 'queries_helper'
require_dependency 'projects_helper'
require_dependency 'projects_controller'
require_dependency File.expand_path('lib/cosmosys/project_language', __dir__)
require_dependency File.expand_path('lib/cosmosys/report_format', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_copy_context', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_copy_reference_registry', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_copy_plan', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_tree_copy_plan', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_tree_copy_executor', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_copy_summary', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_materialization_identity', __dir__)
require_dependency File.expand_path('lib/cosmosys/materialization_reference_rewriter', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_copy_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_native_copy_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_copy_finalizer', __dir__)
require_dependency File.expand_path('lib/cosmosys/projects_controller_copy_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/projects_controller_profile_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_relation_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/document_patch', __dir__)
require_dependency File.expand_path('app/models/cosmosys/report_placeholder', __dir__)
require_dependency File.expand_path('lib/cosmosys/item_kind_registry', __dir__)
require_dependency File.expand_path('lib/cosmosys/report_template_catalog', __dir__)
require_dependency File.expand_path('lib/cosmosys/report_template_inspector', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_profile_registry', __dir__)
require_dependency File.expand_path('lib/cosmosys/tracker_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_status_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_workflow_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/issues_controller_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/documents_controller_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/item_resolver', __dir__)
require_dependency File.expand_path('lib/cosmosys/task_splitter', __dir__)
require_dependency File.expand_path('lib/cosmosys/related_items_creator', __dir__)
require_dependency File.expand_path('lib/cosmosys/dsm_analysis', __dir__)
require_dependency File.expand_path('lib/cosmosys/auto_completes_controller_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_relations_controller_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/chapter_map', __dir__)
require_dependency File.expand_path('lib/cosmosys/chapter_sort', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_tree_scope', __dir__)
require_dependency File.expand_path('lib/cosmosys/sibling_order', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_tree_health', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_tree_audit', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_tree_revision_service', __dir__)
require_dependency File.expand_path('app/models/cosmosys/issue_tree_audit_mailer', __dir__)
require_dependency File.expand_path('lib/cosmosys/dependency_settings', __dir__)
require_dependency File.expand_path('lib/cosmosys/cache_settings', __dir__)
require_dependency File.expand_path('lib/cosmosys/main_report_settings', __dir__)
require_dependency File.expand_path('lib/cosmosys/main_report_text_normalizer', __dir__)
require_dependency File.expand_path('lib/cosmosys/main_report_field_registry', __dir__)
require_dependency File.expand_path('lib/cosmosys/main_report_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/report_placeholder_installer', __dir__)
require_dependency File.expand_path('lib/cosmosys/report_placeholder_diagnostics', __dir__)
require_dependency File.expand_path('lib/cosmosys/report_export_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_items', __dir__)
require_dependency File.expand_path('lib/cosmosys/odf_package_normalizer', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_item_field_registry', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_fields', __dir__)
require_dependency File.expand_path('app/models/cosmosys/template_asset', __dir__)
require_dependency File.expand_path('lib/cosmosys/template_resolver', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_protection_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_row_writer', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_export_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/progress_reporter', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_export_job', __dir__)
require_dependency File.expand_path('app/models/cosmosys/ods_transfer', __dir__)
require_dependency File.expand_path('app/models/cosmosys/ods_transfer_event', __dir__)
require_dependency File.expand_path('app/models/cosmosys/ods_import_identity', __dir__)
require_dependency File.expand_path('app/models/cosmosys/project_snapshot', __dir__)
require_dependency File.expand_path('app/models/cosmosys/negative_status_selection', __dir__)
require_dependency File.expand_path('lib/cosmosys/canonical_json', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_snapshot_selection', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_snapshot_capture', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_snapshot_package', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_snapshot_import_stage', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_snapshot_package_reader', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_snapshot_materialization_plan', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_snapshot_materialization_summary', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_snapshot_materializer', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_text_normalizer', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_import_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_import_job', __dir__)
require_dependency File.expand_path('lib/cosmosys/ods_project_materializer', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_settings_controller', __dir__)
require_dependency File.expand_path('lib/cosmosys/performance_trace', __dir__)
require_dependency File.expand_path('lib/cosmosys/diagram_cache_support', __dir__)
require_dependency File.expand_path('lib/cosmosys/hierarchy_diagram_renderer', __dir__)
require_dependency File.expand_path('lib/cosmosys/hierarchy_diagram_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_hierarchy_diagram_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/dependency_diagram_renderer', __dir__)
require_dependency File.expand_path('lib/cosmosys/dependency_diagram_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_dependency_diagram_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/combined_diagram_renderer', __dir__)
require_dependency File.expand_path('lib/cosmosys/combined_diagram_options', __dir__)
require_dependency File.expand_path('lib/cosmosys/diagram_relation_options', __dir__)
require_dependency File.expand_path('lib/cosmosys/combined_diagram_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_combined_diagram_service', __dir__)
require_dependency File.expand_path('lib/cosmosys/diagram_cache_bootstrap', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_query_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/issue_query_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/presentation_text_registry', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_data_dictionary', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_data_report_scanner', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_data_usage_scanner', __dir__)
require_dependency File.expand_path('lib/cosmosys/project_data_reconciliation', __dir__)
require_dependency File.expand_path('lib/cosmosys/application_helper_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/issues_helper_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/queries_helper_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/projects_helper_patch', __dir__)
require_dependency File.expand_path('lib/cosmosys/hooks', __dir__)

Cosmosys::PresentationTextRegistry.register(:project_data) do |text, project:, user:, formatter:|
  Cosmosys::ProjectDataDictionary.current(project: project, user: user).resolve(text) do |value, entry, _component|
    next value unless formatter

    escaped_value = formatter.call(value)
    tooltip = formatter.call("#{entry.key} — #{entry.name.presence || entry.key} — #{entry.value}")
    content = %(<em class="cosmosys-project-data" title="#{tooltip}">#{escaped_value}</em>)
    link_policy = entry.issue.cosmosys_item_kind.value(:resolved_project_data_links, entry.issue)
    link_enabled = link_policy == true || (link_policy == :user_choice && Cosmosys::ProjectDataRenderState.link_resolutions)
    next content unless link_enabled

    issue_url = Rails.application.routes.url_helpers.issue_url(
      entry.issue, host: Setting.host_name, protocol: Setting.protocol
    )
    %(<a href="#{formatter.call(issue_url)}" data-cosmosys-export-link="1">#{content}</a>)
  end
end

patch_cosmosys_models = proc do
  Project.include Cosmosys::ProjectPatch unless Project < Cosmosys::ProjectPatch
  Project.prepend Cosmosys::ProjectNativeCopyPatch unless Project < Cosmosys::ProjectNativeCopyPatch
  Issue.include Cosmosys::IssuePatch unless Issue < Cosmosys::IssuePatch
  Issue.prepend Cosmosys::IssueWorkflowPatch unless Issue < Cosmosys::IssueWorkflowPatch
  Issue.prepend Cosmosys::IssuePresentationPatch unless Issue < Cosmosys::IssuePresentationPatch
  IssueRelation.include Cosmosys::IssueRelationPatch unless IssueRelation < Cosmosys::IssueRelationPatch
  Issue.prepend Cosmosys::IssueCopyPatch unless Issue < Cosmosys::IssueCopyPatch
  Document.include Cosmosys::DocumentPatch unless Document < Cosmosys::DocumentPatch
  Tracker.include Cosmosys::TrackerPatch unless Tracker < Cosmosys::TrackerPatch
  IssueStatus.include Cosmosys::IssueStatusPatch unless IssueStatus < Cosmosys::IssueStatusPatch
  IssuesController.prepend Cosmosys::IssuesControllerPatch unless IssuesController < Cosmosys::IssuesControllerPatch
  DocumentsController.prepend Cosmosys::DocumentsControllerPatch unless DocumentsController < Cosmosys::DocumentsControllerPatch
  ProjectQuery.prepend Cosmosys::ProjectQueryPatch unless ProjectQuery < Cosmosys::ProjectQueryPatch
  IssueQuery.prepend Cosmosys::IssueQueryPatch unless IssueQuery < Cosmosys::IssueQueryPatch
  ApplicationHelper.prepend Cosmosys::ApplicationHelperPatch unless ApplicationHelper < Cosmosys::ApplicationHelperPatch
  AutoCompletesController.prepend Cosmosys::AutoCompletesControllerPatch unless AutoCompletesController < Cosmosys::AutoCompletesControllerPatch
  IssueRelationsController.prepend Cosmosys::IssueRelationsControllerPatch unless IssueRelationsController < Cosmosys::IssueRelationsControllerPatch
  IssuesHelper.prepend Cosmosys::IssuesHelperPatch unless IssuesHelper < Cosmosys::IssuesHelperPatch
  QueriesHelper.prepend Cosmosys::QueriesHelperPatch unless QueriesHelper < Cosmosys::QueriesHelperPatch
  ProjectsHelper.prepend Cosmosys::ProjectsHelperPatch unless ProjectsHelper < Cosmosys::ProjectsHelperPatch
  ProjectsController.prepend Cosmosys::ProjectsControllerCopyPatch unless ProjectsController < Cosmosys::ProjectsControllerCopyPatch
  ProjectsController.prepend Cosmosys::ProjectsControllerProfilePatch unless ProjectsController < Cosmosys::ProjectsControllerProfilePatch
end

patch_cosmosys_models.call
Rails.application.config.to_prepare(&patch_cosmosys_models)
Rails.application.config.after_initialize { Cosmosys::DiagramCacheBootstrap.invalidate_all_if_enabled! }
