module Cosmosys
  class CatalogRefsController < ApplicationController
    helper :attachments
    helper :custom_fields

    before_action :find_issue, only: :create
    before_action :find_catalog_ref, only: [:show, :edit, :update, :destroy]

    def create
      require_editable!(@issue)
      document = resolve_document(@issue.project, params.dig(:catalog_ref, :document_id))
      unless document
        flash[:error] = l(:error_cosmosys_document_not_found)
        return redirect_to issue_path(@issue, anchor: 'cosmosys-document-references')
      end

      family = params.dig(:catalog_ref, :family).presence || 'R'
      unless Cosmosys::DocumentCatalogEntry::FAMILIES.include?(family)
        flash[:error] = l(:error_invalid_value)
        return redirect_to issue_path(@issue, anchor: 'cosmosys-document-references')
      end
      entry = Cosmosys::DocumentCatalogEntry.find_or_create_for!(document: document, family: family)
      catalog_ref = entry.catalog_refs.build(catalog_ref_params.merge(issue: @issue))
      if catalog_ref.save
        flash[:notice] = l(:notice_successful_create)
      else
        if !entry.catalog_refs.exists?
          project_id = entry.project_id
          entry_family = entry.family
          entry.destroy!
          Cosmosys::DocumentCatalogEntry.compact!(project_id: project_id, family: entry_family)
        end
        flash[:error] = catalog_ref.errors.full_messages.join(', ')
      end
      redirect_to issue_path(@issue, anchor: 'cosmosys-document-references')
    end

    def show
      raise Unauthorized unless @catalog_ref.visible?(User.current)

      @document = @catalog_ref.document
      @project = @document.project
      @attachments = @document.attachments.to_a
      @other_refs = @catalog_ref.document_catalog_entry.catalog_refs.includes(issue: [:project, :tracker]).ordered.select do |other|
        other.id != @catalog_ref.id && other.visible?(User.current)
      end
    end

    def edit
      raise Unauthorized unless @catalog_ref.editable?(User.current)

      @issue = @catalog_ref.issue
    end

    def update
      raise Unauthorized unless @catalog_ref.editable?(User.current)

      if @catalog_ref.update(catalog_ref_params)
        flash[:notice] = l(:notice_successful_update)
        redirect_to cosmosys_catalog_ref_path(@catalog_ref)
      else
        @issue = @catalog_ref.issue
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      raise Unauthorized unless @catalog_ref.editable?(User.current)

      issue = @catalog_ref.issue
      if @catalog_ref.destroy
        flash[:notice] = l(:notice_successful_delete)
      else
        flash[:error] = @catalog_ref.errors.full_messages.join(', ')
      end
      redirect_to issue_path(issue, anchor: 'cosmosys-document-references')
    end

    private

    def find_issue
      @issue = Issue.find(params[:issue_id])
      raise Unauthorized unless @issue.visible?(User.current)
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    def find_catalog_ref
      @catalog_ref = Cosmosys::CatalogRef.includes(:issue, document_catalog_entry: :document).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    def require_editable!(issue)
      raise Unauthorized unless issue.editable?(User.current) && User.current.allowed_to?(:edit_documents, issue.project)
    end

    def resolve_document(project, document_id)
      project.documents.visible(User.current).find_by(id: document_id)
    end

    def catalog_ref_params
      (params[:catalog_ref] || params[:cosmosys_catalog_ref] || ActionController::Parameters.new)
        .permit(:sense, :location)
    end
  end
end
