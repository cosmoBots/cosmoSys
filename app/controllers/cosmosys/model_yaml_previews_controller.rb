require_relative '../../../lib/cosmosys/model_yaml_preview'
require_relative '../../../lib/cosmosys/model_yaml_capture'
require_relative '../../../lib/cosmosys/view_audience_diagram_data'

module Cosmosys
  class ModelYamlPreviewsController < ApplicationController
    before_action :find_source

    def show
      @source = @issue || @project
      @preview_path = @issue ? issue_cosmosys_model_yaml_path(@issue) : project_cosmosys_model_yaml_path(@project)
      @attachments = @source.attachments.select { |attachment| attachment.filename.match?(/\.ya?ml\z/i) && attachment.visible?(User.current) }
      @yaml = params[:yaml].is_a?(String) ? params[:yaml] : ''
      unless request.post?
        @yaml = @source.description.to_s[/```(?:cosmosys-model|yaml)\s*\n(.*?)\n```/m, 1].to_s
        if params[:example] == '1' || @yaml.blank?
          selection = if @issue
                        ViewAudienceDiagramData.for_item(@issue, scope: :node_and_descendants, user: User.current, relation_types: %w[blocks precedes relates])
                      else
                        ViewAudienceDiagramData.for_project(@project, scope: :project, user: User.current, relation_types: %w[blocks precedes relates])
                      end
          @yaml = ModelYamlCapture.call(entries: selection.root_entries, relations: selection.relations,
            profile: @project.csys_project_profile, focus: @issue)
        end
        return
      end

      if params[:yaml_file].respond_to?(:read)
        @yaml = params[:yaml_file].read(ModelYamlDocument::MAX_BYTES + 1)
      elsif params[:attachment_id].present?
        attachment = @attachments.find { |candidate| candidate.id.to_s == params[:attachment_id].to_s }
        raise ModelYamlDocument::Invalid, 'YAML attachment not available on this item' unless attachment
        @yaml = File.open(attachment.diskfile, 'rb') { |file| file.read(ModelYamlDocument::MAX_BYTES + 1) }
      end
      document = ModelYamlDocument.new(@yaml, expected_profile: @project.csys_project_profile)
      @svg = ModelYamlPreview.new(document).svg
    rescue ModelYamlDocument::Invalid, Timeout::Error => error
      flash.now[:error] = error.message
      render :show, status: :unprocessable_entity
    end

    private

    def find_source
      if params[:issue_id]
        @issue = Issue.find(params[:issue_id])
        @project = @issue.project
        raise Unauthorized unless @issue.visible?(User.current)
      else
        @project = Project.find(params[:project_id])
      end
      raise Unauthorized unless @project.visible?(User.current) && User.current.allowed_to?(:view_issues, @project)
      raise ActiveRecord::RecordNotFound unless ModelYamlDialects.registered?(@project.csys_project_profile)
    rescue ActiveRecord::RecordNotFound
      render_404
    end
  end
end
