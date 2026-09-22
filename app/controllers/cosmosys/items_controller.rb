require 'digest'
require 'securerandom'

module Cosmosys
  class ItemsController < ApplicationController
    menu_item :cosmosys
    helper :queries

    before_action :find_project_by_project_id
    before_action :authenticate_api_user!, only: [:diagram_export, :resolve]
    before_action :find_export_issue, only: [:diagram_export, :diagram_panel]
    before_action :authorize_project_read, only: [:index, :overview, :report, :report_diagram, :report_export, :ods_export, :tree, :data, :dsm, :details, :resolve]
    before_action :find_report_diagram_issue, only: :report_diagram
    before_action :authorize_diagram_read, only: [:diagram_export, :diagram_panel]
    before_action :authorize_diagram_layout_change, only: :diagram_panel
    before_action :find_tree_issue, only: :move
    before_action :authorize_tree_reorder, only: :move
    before_action :find_rebuild_issue, only: :rebuild_tree
    before_action :authorize_tree_repair, only: :rebuild_tree
    before_action :find_detail_issue, only: :details
    around_action :use_project_language, only: :report_diagram

    accept_api_auth :resolve

    def index
      redirect_to action: :tree, project_id: @project
    end

    def overview
      @scope = @project.cosmosys_scope
      @tree_health_problem = Cosmosys::IssueTreeHealth.first_problem(visible_tree_issues)
      @recent_issues = visible_tree_issues.
        reorder(created_on: :desc).
        limit(25)

      render :index
    end

    def report
      prepare_report_view
    end

    def report_export
      html = @project.with_cosmosys_locale do
        prepare_report_view
        @report_diagrams = resolve_report_diagrams
        body = render_to_string(
          partial: 'cosmosys/items/report_body',
          formats: [:html],
          locals: { server_export: true }
        )
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>#{ERB::Util.html_escape(@project.name)}</title></head><body>#{body}</body></html>"
      end

      result = Cosmosys::ReportExportService.new(
        @project,
        html: html,
        format: params[:format],
        user: User.current
      ).call
      send_data(
        result.data,
        filename: result.filename,
        type: result.content_type,
        disposition: 'attachment'
      )
    rescue Cosmosys::ReportExportService::ExportError => error
      render json: { error: error.message }, status: :unprocessable_entity
    end

    def prepare_report_view
      @scope = @project.cosmosys_scope
      @report_query = Cosmosys::MainReportFieldRegistry.query_for_project(@project, user: User.current)
      @report_selected_column_names, @report_field_presentations, @report_options = report_view_field_selection
      @report_query.column_names = @report_selected_column_names
      @report_available_columns = Cosmosys::MainReportFieldRegistry.available_inline_columns_for_project(@project, user: User.current)
      @report_columns_by_name = @report_available_columns.index_by { |column| column.name.to_s }
      @report = @project.with_cosmosys_locale do
        Cosmosys::MainReportService.new(
          @project,
          user: User.current,
          column_names: @report_selected_column_names,
          field_presentations: @report_field_presentations,
          options: @report_options
        ).build
      end
      Cosmosys::ProjectDataReportScanner.new(@report, user: User.current).call
      @tree_health_problem = Cosmosys::IssueTreeHealth.first_problem(@report.local_issues)
      @report_placeholder_diagnostics = Cosmosys::ReportPlaceholderDiagnostics.new(@project, user: User.current).call
    end
    private :prepare_report_view

    def report_diagram
      kind = params[:kind].to_s
      diagram =
        case kind
        when 'combined'
          options = Cosmosys::CombinedDiagramOptions.resolve(user: User.current, project: @report_diagram_issue.project, issue: @report_diagram_issue)
          relation_options = resolve_diagram_relation_options_for(@report_diagram_issue, kind: 'combined')
          Cosmosys::CombinedDiagramService.fetch(
            @report_diagram_issue,
            mode: relation_options.mode,
            render_variant: options.render_variant,
            layout_mode: options.layout_mode,
            include_document_references: false
          )
        when 'hierarchy'
          traversal = resolve_diagram_relation_options_for(@report_diagram_issue, kind: 'hierarchy')
          Cosmosys::HierarchyDiagramService.fetch(@report_diagram_issue, mode: traversal.mode)
        when 'dependency'
          relations = resolve_diagram_relation_options_for(@report_diagram_issue, kind: 'dependency')
          Cosmosys::DependencyDiagramService.fetch(@report_diagram_issue, mode: relations.mode, include_document_references: false, relation_types: relations.relation_types)
        else
          return render_404
        end

      render partial: 'cosmosys/items/report_diagram', locals: { kind: kind, diagram: diagram }
    end

    def ods_export
      include_subprojects = ActiveModel::Type::Boolean.new.cast(params[:include_subprojects]) || false
      writer = params[:writer].to_s.presence || Cosmosys::OdsExportService::DEFAULT_WRITER
      unless Cosmosys::OdsExportService::WRITERS.include?(writer)
        return render json: { error: l(:text_cosmosys_ods_export_writer_invalid) }, status: :unprocessable_entity
      end
      transfer = Cosmosys::OdsTransfer.create!(
        project: @project,
        user: User.current,
        direction: 'export',
        state: 'queued',
        export_id: SecureRandom.uuid,
        format_version: Cosmosys::OdsExportService::FORMAT_VERSION,
        include_subprojects: include_subprojects,
        summary: { 'progress' => 0, 'progress_phase' => 'queued', 'writer' => writer }
      )
      Cosmosys::OdsExportJob.perform_later(transfer.id, request.base_url, writer)
      render json: {
        transfer_id: transfer.id,
        status_url: status_project_cosmosys_ods_transfer_path(@project, transfer)
      }, status: :accepted
    rescue Cosmosys::OdsExportService::ExportError => error
      render json: { error: error.message }, status: :unprocessable_entity
    end

    def tree
      prepare_tree_view
    end

    def dsm
      @dsm_payload = Cosmosys::DsmAnalysis.new(@project, user: User.current).as_json
      @dsm_payload[:labels] = {
        sequence: l(:label_cosmosys_dsm_sequence), item: l(:label_issue_plural),
        backward: l(:label_cosmosys_dsm_backward), restricted: l(:label_cosmosys_dsm_restricted),
        planning: l(:label_cosmosys_dsm_planning), feedback: l(:label_cosmosys_dsm_feedback_groups),
        distance: l(:label_cosmosys_dsm_max_distance), projection: l(:label_cosmosys_dsm_projection),
        expand: l(:label_cosmosys_dsm_expand), compact: l(:label_cosmosys_dsm_compact),
        empty: l(:label_no_data)
      }
    end

    def data
      @data_mode = params[:mode].to_s == 'used' ? :used : :available
      dictionary = Cosmosys::ProjectDataDictionary.current(project: @project, user: User.current)
      @data_entries =
        case @data_mode
        when :available
          dictionary.definitions
        when :used
          Cosmosys::ProjectDataScopeScanner.new(@project, user: User.current).call.map do |entry|
            Cosmosys::ProjectDataDictionary::Entry.new(
              key: entry.fetch(:key), name: entry.fetch(:name),
              value: entry.fetch(:value), issue: entry.fetch(:issue)
            )
          end
        end
    end

    def details
      render partial: 'issue_details', locals: { issue: @issue }
    end

    def resolve
      issue = Cosmosys::ItemResolver.new(project: @project, user: User.current).resolve(params[:csid])
      return render_404 unless issue

      respond_to do |format|
        format.html { redirect_to issue_path(issue) }
        format.json do
          render json: {
            item: {
              id: issue.id,
              csid: issue.csid,
              csidnum: issue.csidnum,
              subject: issue.subject,
              description: issue.description,
              project: { id: issue.project_id, identifier: issue.project.identifier, cscode: issue.project.cscode },
              tracker: { id: issue.tracker_id, name: issue.tracker.name },
              item_kind: issue.cosmosys_item_kind_key,
              status: { id: issue.status_id, name: issue.status.name },
              url: issue_url(issue)
            }
          }
        end
      end
    end

    def diagram_export
      diagram = fetch_export_diagram
      return if performed? || diagram.blank?

      case params[:diagram_format].to_s
      when 'gv'
        send_data(
          diagram.dot_body.to_s,
          type: 'text/vnd.graphviz; charset=utf-8',
          disposition: 'inline',
          filename: export_filename('gv')
        )
      when 'svg'
        send_data(
          diagram.svg_body.to_s,
          type: 'image/svg+xml; charset=utf-8',
          disposition: 'inline',
          filename: export_filename('svg')
        )
      else
        render_404
      end
    end

    def diagram_panel
      case params[:kind].to_s
      when 'hierarchy'
        relation_options = resolve_diagram_relation_options(kind: 'hierarchy', persist: true)
        hierarchy_diagram = @export_issue ? Cosmosys::HierarchyDiagramService.fetch(@export_issue, mode: relation_options.mode) : Cosmosys::ProjectHierarchyDiagramService.fetch(@project, mode: relation_options.mode)
        render partial: 'cosmosys/items/hierarchy_diagram_panel', locals: {
          project: @project, issue: @export_issue, hierarchy_diagram: hierarchy_diagram,
          relation_options: relation_options, can_edit_layout: diagram_layout_editable?
        }
      when 'combined'
        relation_options = resolve_diagram_relation_options(kind: 'combined', persist: true)
        options = resolve_combined_diagram_options(persist: true)
        combined_diagram = fetch_combined_diagram(options, relation_options)
        render partial: 'cosmosys/items/combined_diagram_panel', locals: {
          project: @project, issue: @export_issue, combined_diagram: combined_diagram,
          diagram_options: options, relation_options: relation_options,
          can_edit_layout: diagram_layout_editable?
        }
      when 'dependency'
        relation_options = resolve_diagram_relation_options(kind: 'dependency', persist: true)
        dependency_diagram = fetch_dependency_diagram(relation_options)
        render partial: 'cosmosys/items/dependency_diagram_panel', locals: {
          project: @project, issue: @export_issue, dependency_diagram: dependency_diagram,
          relation_options: relation_options, can_edit_layout: diagram_layout_editable?
        }
      else
        render_404
      end
    end

    def move
      saved = false
      Issue.transaction do
        apply_move_operation
        saved = @issue.save
        raise ActiveRecord::Rollback unless saved
      end

      if saved
        flash[:notice] = l(:notice_successful_update)
      else
        flash[:error] = @issue.errors.full_messages.to_sentence
      end

      redirect_to action: move_redirect_action, project_id: @project
    end

    def rebuild_tree
      result = Cosmosys::IssueTreeOrderRepair.new(@project, user: User.current).call
      flash[:notice] = l(:notice_cosmosys_tree_order_repaired,
                         families: result.fetch(:families), items: result.fetch(:items))
      redirect_back fallback_location: issue_path(@issue)
    end

    private

    def resolve_report_diagrams
      @report.toc_entries.each_with_object({}) do |section, diagrams|
        section.issue.cosmosys_report_diagram_kinds(@report.options).each do |kind|
          diagrams[[section.issue.id, kind]] = fetch_report_diagram(section.issue, kind)
        end
      end
    end

    def fetch_report_diagram(issue, kind)
      case kind
      when 'combined'
        options = Cosmosys::CombinedDiagramOptions.resolve(user: User.current, project: issue.project, issue: issue)
        relation_options = resolve_diagram_relation_options_for(issue, kind: 'combined')
        Cosmosys::CombinedDiagramService.fetch(
          issue,
          mode: relation_options.mode,
          render_variant: options.render_variant,
          layout_mode: options.layout_mode,
          include_document_references: false
        )
      when 'hierarchy'
        traversal = resolve_diagram_relation_options_for(issue, kind: 'hierarchy')
        Cosmosys::HierarchyDiagramService.fetch(issue, mode: traversal.mode)
      when 'dependency'
        relations = resolve_diagram_relation_options_for(issue, kind: 'dependency')
        Cosmosys::DependencyDiagramService.fetch(issue, mode: relations.mode, include_document_references: false, relation_types: relations.relation_types)
      end
    end

    def use_project_language(&block)
      @project.with_cosmosys_locale(&block)
    end

    def find_report_diagram_issue
      @report_diagram_issue = @project.issues.visible(User.current).find_by(id: params[:issue_id])
      render_404 unless @report_diagram_issue
    end

    def authorize_project_read
      deny_access unless @project.visible?(User.current)
    end

    def prepare_tree_view
      @scope = @project.cosmosys_scope
      @tree_scope = Cosmosys::ProjectTreeScope.new(
        @project,
        user: User.current,
        include_negative: ActiveModel::Type::Boolean.new.cast(params[:include_negative_items])
      )
      @tree_entries = @tree_scope.entries
      @tree_issues = @tree_scope.rendered_issues
      @tree_orphaned_issues = @tree_scope.orphaned_issues
      @local_tree_issues = @tree_scope.local_issues
      @chapter_map = @project.cosmosys_chapter_map(@local_tree_issues)
      @project_ancestor_map = build_project_ancestor_map(@tree_issues)
      @reorderable_issue_ids = @local_tree_issues.select { |issue| User.current.allowed_to?(:edit_issues, issue.project) }.map(&:id)
      @tree_health_problem = Cosmosys::IssueTreeHealth.first_problem(@local_tree_issues)
    end

    def visible_tree_issues
      Issue.visible(User.current).
        where(project_id: @project.project_root.self_and_descendants.select(:id)).
        includes(:project, :parent).
        order(:project_id, :parent_id, :csposition, :lft, :id)
    end

    def report_view_field_selection
      available_names = Cosmosys::MainReportFieldRegistry.available_column_names_for_project(@project, user: User.current)
      requested_names = Array(params[:report_columns]).map(&:to_s).reject(&:blank?)
      selected_names =
        if requested_names.present?
          requested_names.select { |name| available_names.include?(name) }
        else
          @project.cosmosys_report_column_names(user: User.current)
        end
      selected_names = @project.cosmosys_report_column_names(user: User.current) if selected_names.blank?

      raw_presentations_param = params[:report_field_presentations]
      raw_presentations =
        case raw_presentations_param
        when ActionController::Parameters
          raw_presentations_param.to_unsafe_h
        when Hash
          raw_presentations_param
        else
          {}
        end
      base_presentations =
        if raw_presentations.present?
          raw_presentations.transform_keys(&:to_s).transform_values(&:to_s)
        else
          @project.cosmosys_report_field_presentations(user: User.current)
        end

      field_presentations = selected_names.each_with_object({}) do |name, result|
        mode = base_presentations[name].to_s
        result[name] = Cosmosys::MainReportFieldRegistry.valid_representation_mode?(mode) ? mode : Cosmosys::MainReportFieldRegistry::DEFAULT_REPRESENTATION_MODE
      end

      requested_options = params[:report_options]
      options = requested_options.present? ? Cosmosys::MainReportSettings.normalize_options(requested_options) : @project.cosmosys_report_options
      if params.key?(:include_negative_items)
        options['include_negative_items'] = ActiveModel::Type::Boolean.new.cast(params[:include_negative_items])
      end

      [selected_names, field_presentations, options]
    end

    def find_tree_issue
      @issue = visible_tree_issues.find(params[:issue_id])
    end

    def authorize_tree_reorder
      deny_access unless User.current.allowed_to?(:edit_issues, @issue.project)
    end

    def parent_issue_id_param
      raw = params[:parent_issue_id].to_s.strip
      return nil if raw.blank?

      visible_tree_issues.find(raw).id
    end

    def target_issue_param
      raw = params[:target_issue_id].to_s.strip
      return nil if raw.blank?

      visible_tree_issues.find(raw)
    end

    def move_mode_param
      mode = params[:move_mode].to_s
      %w[child root before after].include?(mode) ? mode : 'child'
    end

    def apply_move_operation
      case move_mode_param
      when 'root'
        @issue.parent_issue_id = nil
      when 'before'
        target_issue = target_issue_param
        Cosmosys::SiblingOrder.move_before(@issue, target_issue)
      when 'after'
        target_issue = target_issue_param
        Cosmosys::SiblingOrder.move_after(@issue, target_issue)
      else
        @issue.parent_issue_id = parent_issue_id_param
      end
    end

    def build_project_ancestor_map(issues)
      projects = issues.map(&:project).compact.uniq
      projects.each_with_object({}) do |project, map|
        map[project.id] = project.self_and_ancestors.pluck(:id)
      end
    end

    def find_rebuild_issue
      @issue = Issue.find(params[:issue_id])
      raise ActiveRecord::RecordNotFound unless @project.project_root.self_and_descendants.exists?(id: @issue.project_id)
    end

    def find_detail_issue
      @issue = visible_tree_issues.find(params[:issue_id])
    end

    def find_export_issue
      return unless params[:issue_id].present?

      @export_issue = visible_tree_issues.find(params[:issue_id])
    end

    def authorize_diagram_read
      # A diagram is another representation of its owner, so it follows
      # Redmine's native visibility for the issue or project instead of the
      # any plugin-specific permission.
      return if @export_issue&.visible?(User.current)
      return if !params[:issue_id].present? && @project.visible?(User.current)

      render_403
    end

    def fetch_export_diagram
      case params[:kind].to_s
      when 'hierarchy'
        traversal = resolve_diagram_relation_options(kind: 'hierarchy')
        @export_issue ? Cosmosys::HierarchyDiagramService.fetch(@export_issue, mode: traversal.mode) : Cosmosys::ProjectHierarchyDiagramService.fetch(@project, mode: traversal.mode)
      when 'dependency'
        fetch_dependency_diagram(resolve_diagram_relation_options(kind: 'dependency'))
      when 'combined'
        options = resolve_combined_diagram_options
        fetch_combined_diagram(options, resolve_diagram_relation_options(kind: 'combined'))
      else
        render_404
        nil
      end
    end

    def export_filename(extension)
      owner = @export_issue ? @export_issue.csid.to_s : @project.identifier.to_s
      "cosmosys-#{params[:kind]}-#{owner}.#{extension}"
    end

    def resolve_combined_diagram_options(persist: false)
      Cosmosys::CombinedDiagramOptions.resolve(
        user: User.current,
        project: @project,
        issue: @export_issue,
        render_variant: params[:render_variant],
        layout_mode: params[:combined_layout_mode],
        persist: persist
      )
    end

    def resolve_diagram_relation_options(kind:, persist: false)
      requested_layers = params.key?(:visible_layers_present) ? Array(params[:visible_layers]) : nil
      Cosmosys::DiagramRelationOptions.resolve(
        user: User.current, project: @project, issue: @export_issue,
        kind: kind, visible_layers: requested_layers, persist: persist
      )
    end

    def resolve_diagram_relation_options_for(issue, kind:)
      Cosmosys::DiagramRelationOptions.resolve(
        user: User.current, project: issue.project, issue: issue, kind: kind
      )
    end

    def fetch_dependency_diagram(options)
      arguments = {
        mode: options.mode,
        relation_types: options.relation_types,
        include_document_references: options.include_document_references?
      }
      @export_issue ? Cosmosys::DependencyDiagramService.fetch(@export_issue, **arguments) : Cosmosys::ProjectDependencyDiagramService.fetch(@project, **arguments)
    end

    def fetch_combined_diagram(options, relation_options)
      arguments = {
        mode: relation_options.mode,
        render_variant: options.render_variant,
        layout_mode: options.layout_mode,
        relation_types: relation_options.relation_types,
        include_document_references: relation_options.include_document_references?
      }
      @export_issue ? Cosmosys::CombinedDiagramService.fetch(@export_issue, **arguments) : Cosmosys::ProjectCombinedDiagramService.fetch(@project, **arguments)
    end

    def authorize_diagram_layout_change
      render_403 if diagram_layout_change_requested? && !diagram_layout_editable?
    end

    def diagram_layout_change_requested?
      params[:render_variant].present? || params[:combined_layout_mode].present? || params.key?(:visible_layers_present)
    end

    def diagram_layout_editable?
      if @export_issue
        @export_issue.editable?(User.current)
      else
        User.current.allowed_to?(:edit_project, @project)
      end
    end

    def require_admin_user
      render_403 unless User.current.admin?
    end

    def authorize_tree_repair
      deny_access unless User.current.admin? || User.current.allowed_to?(:edit_project, @project)
    end

    def authenticate_api_user!
      # Accept the standard Redmine API key header for integrations and keep
      # query-string `key` support for direct browser/open-in-tab exports.
      key = request.headers['X-Redmine-API-Key'].to_s.strip
      key = params[:key].to_s.strip if key.blank?
      return if key.blank?

      user = User.find_by_api_key(key)
      if user&.active?
        User.current = user
      else
        render_403
      end
    end

    def move_redirect_action
      :tree
    end
  end
end
