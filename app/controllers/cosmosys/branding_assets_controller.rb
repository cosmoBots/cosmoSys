module Cosmosys
  class BrandingAssetsController < ApplicationController
    layout 'admin', only: :index
    before_action :require_admin, only: [:index, :update_instance]
    before_action :find_project, only: :update_project
    before_action :authorize_project, only: :update_project
    before_action :find_asset, only: :show

    def index
      @asset = Cosmosys::BrandingAsset.instance_asset
    end

    def show
      return deny_access unless @asset.visible?(User.current)
      attachment = @asset.attachment
      return head :not_found unless attachment&.readable?

      public_cache = @asset.project.nil? || @asset.project.is_public?
      if stale?(etag: attachment.digest, last_modified: attachment.created_on, public: public_cache)
        send_file attachment.diskfile, filename: attachment.filename,
                  type: attachment.content_type, disposition: 'inline'
      end
    end

    def update_instance
      update_scope(nil, cosmosys_branding_path)
    end

    def update_project
      update_scope(@project, settings_project_path(@project, tab: 'cosmosys'))
    end

    private

    def update_scope(project, destination)
      current = Cosmosys::BrandingAsset.find_by(project_id: project&.id)
      if ActiveModel::Type::Boolean.new.cast(params[:remove_branding])
        current&.destroy!
      elsif params[:branding_file].respond_to?(:read)
        Cosmosys::BrandingAsset.replace!(
          project: project,
          upload: params[:branding_file],
          diffuse_effect: ActiveModel::Type::Boolean.new.cast(params[:diffuse_effect])
        )
      elsif current
        current.update!(diffuse_effect: ActiveModel::Type::Boolean.new.cast(params[:diffuse_effect]))
      end
      flash[:notice] = l(:notice_successful_update)
      redirect_to destination
    rescue Cosmosys::BrandingAsset::InvalidUpload => error
      flash[:error] = error.message
      redirect_to destination
    end

    def find_project
      @project = Project.find(params[:project_id])
    end

    def authorize_project
      deny_access unless User.current.allowed_to?(:edit_project, @project)
    end

    def find_asset
      @asset = Cosmosys::BrandingAsset.find(params[:id])
    end
  end
end
