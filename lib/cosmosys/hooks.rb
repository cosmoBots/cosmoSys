module Cosmosys
  class Hooks < Redmine::Hook::ViewListener
    %w[combined dependency hierarchy].each do |kind|
      Cosmosys::IssuePanelRegistry.register(
        key: "diagram_#{kind}", location: :content,
        title: "label_cosmosys_#{kind}_diagram",
        url: ->(view, issue) { view.cosmosys_diagram_panel_path(project_id: issue.project.identifier, kind: kind, issue_id: issue.id) },
        available: ->(issue, _user) { issue.cosmosys_diagram_visible? },
        default: ->(issue, _user) { issue.cosmosys_preferred_report_diagram.to_s == kind }
      )
    end

    Cosmosys::IssuePanelRegistry.register(
      key: 'tree', location: :sidebar, title: :label_cosmosys_issue_tree_fragment,
      url: ->(view, issue) { view.cosmosys_tree_fragment_path(project_id: issue.project.project_root.identifier, issue_id: issue.id) },
      available: lambda do |issue, user|
        Issue.visible(user).where(project_id: issue.project.project_root.self_and_descendants.select(:id), parent_id: issue.id).
          includes(:tracker, :status).
          to_a.any? { |child| child.cosmosys_tree_visible? && child.cosmosys_positive? }
      end
    )

    render_on :view_projects_form,
      { partial: 'hooks/cosmosys/project_form_fields' }
    render_on :view_projects_copy_only_items,
      { partial: 'hooks/cosmosys/project_copy_options' }
    render_on :view_projects_show_left,
      { partial: 'hooks/cosmosys/project_overview' }
    render_on :view_issues_show_description_bottom,
      { partial: 'hooks/cosmosys/item_operations' },
      { partial: 'hooks/cosmosys/issue_tree_warning' },
      { partial: 'hooks/cosmosys/issue_panel_tabs' },
      { partial: 'hooks/cosmosys/catalog_refs' },
      { partial: 'hooks/cosmosys/approved_presentation_baseline' },
      { partial: 'hooks/cosmosys/used_project_data' }
    render_on :view_issues_sidebar_queries_bottom,
      { partial: 'hooks/cosmosys/issue_sidebar_panel_tabs' }
    render_on :view_issues_form_details_bottom,
      { partial: 'hooks/cosmosys/report_placeholder_field' },
      { partial: 'hooks/cosmosys/negative_status_field' },
      { partial: 'hooks/cosmosys/preferred_report_diagram_field' },
      { partial: 'hooks/cosmosys/item_external_metadata_fields' },
      { partial: 'hooks/cosmosys/datum_fields' }
    render_on :view_issues_show_details_bottom,
      { partial: 'hooks/cosmosys/preferred_report_diagram_detail' },
      { partial: 'hooks/cosmosys/item_external_metadata_details' },
      { partial: 'hooks/cosmosys/datum_details' }
    render_on :view_layouts_base_html_head,
      { partial: 'hooks/cosmosys/html_head' }
    render_on :view_layouts_base_body_bottom,
      { partial: 'hooks/cosmosys/branding' }
    render_on :view_settings_general_form,
      { partial: 'hooks/cosmosys/text_formatting_support' }
    render_on :view_issue_statuses_form,
      { partial: 'hooks/cosmosys/issue_status_outcome' }

    def model_project_copy_before_save(context = {})
      copy_context = Cosmosys::ProjectCopyContext.current
      return unless copy_context

      Cosmosys::ProjectCopyFinalizer.new(copy_context, context.fetch(:destination_project)).call
    end
  end
end
