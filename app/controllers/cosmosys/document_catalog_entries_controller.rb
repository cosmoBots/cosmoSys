module Cosmosys
  class DocumentCatalogEntriesController < ApplicationController
    menu_item :cosmosys
    before_action :find_project
    before_action :authorize_view
    before_action :find_entry, only: [:show, :update]

    def index
      @entries_by_family = Cosmosys::DocumentCatalogEntry.where(project_id: @project.id)
                                                          .includes(:document, catalog_refs: :issue)
                                                          .ordered
                                                          .group_by(&:family)
    end

    def show
      raise Unauthorized unless @entry.document.visible?(User.current)

      @document = @entry.document
      @catalog_refs = @entry.catalog_refs.includes(issue: [:project, :tracker]).ordered.select do |catalog_ref|
        catalog_ref.visible?(User.current)
      end
    end

    def update
      raise Unauthorized unless User.current.allowed_to?(:edit_documents, @project)

      target_position = case params[:move]
                        when 'up' then @entry.position - 1
                        when 'down' then @entry.position + 1
                        else params[:position]
                        end
      @entry.move_to!(target_position)
      flash[:notice] = l(:notice_successful_update)
      redirect_to project_cosmosys_document_catalog_path(@project)
    end

    def create_report_placeholders
      raise Unauthorized unless User.current.allowed_to?(:add_issues, @project)

      result = Cosmosys::ReportPlaceholderInstaller.new(@project, user: User.current).call
      flash[:notice] = if result.created.any?
                         l(:notice_cosmosys_report_placeholders_created, count: result.created.length)
                       else
                         l(:notice_cosmosys_report_placeholders_already_exist)
                       end
      redirect_to project_cosmosys_document_catalog_path(@project)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => error
      flash[:error] = error.message
      redirect_to project_cosmosys_document_catalog_path(@project)
    end

    private

    def find_project
      @project = Project.find(params[:project_id])
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    def authorize_view
      raise Unauthorized unless User.current.allowed_to?(:view_documents, @project)
    end

    def find_entry
      @entry = Cosmosys::DocumentCatalogEntry.find_by!(id: params[:id], project_id: @project.id)
    rescue ActiveRecord::RecordNotFound
      render_404
    end
  end
end
