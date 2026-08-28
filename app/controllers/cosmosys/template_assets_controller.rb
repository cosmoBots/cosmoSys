require 'digest'
require 'fileutils'
require 'securerandom'
require 'tempfile'

module Cosmosys
  class TemplateAssetsController < ApplicationController
    layout 'admin'
    menu_item :cosmosys_template_assets
    before_action :require_admin
    before_action :find_asset, only: :destroy

    def index
      @assets = Cosmosys::TemplateAsset.order(:name, :id)
    end

    def create
      upload = params[:template_file]
      name = params[:name].to_s.strip
      kind = params[:kind].to_s
      kind = 'ods' unless Cosmosys::TemplateAsset::KINDS.include?(kind)
      unless upload.respond_to?(:read) && name.present?
        flash[:error] = l(:error_cosmosys_template_name_and_file_required)
        return redirect_to cosmosys_template_assets_path
      end

      data = upload.read
      if data.blank? || data.bytesize > Cosmosys::TemplateAsset::MAX_BYTES
        flash[:error] = l(:error_cosmosys_template_invalid_size)
        return redirect_to cosmosys_template_assets_path
      end
      kind == 'ods' ? validate_ods!(data) : validate_report!(data)

      extension = kind == 'ods' ? 'ods' : 'odt'
      storage_key = "#{SecureRandom.uuid}.#{extension}"
      path = Cosmosys::TemplateAsset.storage_root(kind).join(storage_key)
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, data)
      asset = Cosmosys::TemplateAsset.create!(
        name: name,
        kind: kind,
        storage_key: storage_key,
        original_filename: upload.original_filename.to_s,
        sha256: Digest::SHA256.hexdigest(data),
        byte_size: data.bytesize,
        created_by: User.current
      )
      flash[:notice] = l(:notice_cosmosys_template_uploaded, name: asset.name)
      redirect_to cosmosys_template_assets_path
    rescue StandardError => error
      File.delete(path) if defined?(path) && path&.file?
      flash[:error] = error.message
      redirect_to cosmosys_template_assets_path
    end

    def destroy
      if @asset.in_use?
        flash[:error] = l(:error_cosmosys_template_in_use)
      else
        @asset.destroy!
        @asset.remove_file!
        flash[:notice] = l(:notice_successful_delete)
      end
      redirect_to cosmosys_template_assets_path
    end

    private

    def find_asset
      @asset = Cosmosys::TemplateAsset.find(params[:id])
    end

    def validate_ods!(data)
      raise l(:error_cosmosys_template_not_ods) unless data.start_with?('PK')

      Cosmosys::OdsItems.load_rspreadsheet!
      Tempfile.create(['cosmosys-template', '.ods']) do |file|
        file.binmode
        file.write(data)
        file.flush
        workbook = ::Rspreadsheet.open(file.path)
        missing = %w[Items ExtraFields Dict Documents Catalog].reject { |sheet| workbook.worksheets(sheet) }
        raise l(:error_cosmosys_template_missing_sheets, sheets: missing.join(', ')) if missing.any?
      end
    rescue Zip::Error, LibXML::XML::Error => error
      raise l(:error_cosmosys_template_not_ods), cause: error
    end

    def validate_report!(data)
      raise l(:error_cosmosys_template_not_report) unless data.start_with?('PK')
      Tempfile.create(['cosmosys-report-template', '.odt']) do |file|
        file.binmode
        file.write(data)
        file.flush
        Cosmosys::ReportTemplateInspector.call(file.path)
        Zip::File.open(file.path) do |archive|
          %w[mimetype content.xml styles.xml].each { |entry| archive.get_entry(entry) }
        end
      end
    rescue Zip::Error, ArgumentError => error
      raise l(:error_cosmosys_template_not_report), cause: error
    end
  end
end
