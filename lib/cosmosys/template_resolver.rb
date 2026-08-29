module Cosmosys
  class TemplateResolver
    Resolution = Struct.new(:kind, :path, :asset, :source_project, :profile, :catalog_template, keyword_init: true) do
      def identifier
        return "#{kind}:asset:#{asset.id}:#{asset.sha256}" if asset
        return "#{kind}:catalog:#{catalog_template.key}" if catalog_template

        "#{kind}:profile:#{profile.key}:#{path}"
      end
    end

    def self.ods_for(project)
      each_same_profile_ancestor(project) do |candidate|
        asset = candidate.cosmosys_ods_template_asset
        if asset
          raise "ODS template asset #{asset.id} is inactive" unless asset.active?
          raise "ODS template asset file is missing: #{asset.source_path}" unless asset.source_path.file?

          return Resolution.new(kind: 'ods', path: asset.source_path, asset: asset, source_project: candidate, profile: project.cosmosys_project_profile_definition)
        end
      end

      profile = project.cosmosys_project_profile_definition
      path = Rails.root.join(profile.ods_export_template)
      Resolution.new(kind: 'ods', path: path, profile: profile)
    end

    def self.report_for(project)
      profile = project.cosmosys_project_profile_definition
      each_same_profile_ancestor(project) do |candidate|
        asset = candidate.cosmosys_report_template_asset
        if asset
          raise "Report template asset #{asset.id} is inactive" unless asset.active?
          raise "Report template asset file is missing: #{asset.source_path}" unless asset.source_path.file?

          return Resolution.new(kind: 'report', path: asset.source_path, asset: asset, source_project: candidate, profile: profile)
        end

        catalog_template = Cosmosys::ReportTemplateCatalog.fetch(candidate.csys_report_template_key)
        next unless catalog_template

        return Resolution.new(
          kind: 'report', path: Rails.root.join(catalog_template.path), catalog_template: catalog_template,
          source_project: candidate, profile: profile
        )
      end

      Resolution.new(kind: 'report', path: Rails.root.join(profile.report_export_template), profile: profile)
    end

    def self.each_same_profile_ancestor(project)
      profile_key = project.csys_project_profile
      candidate = project
      while candidate
        yield candidate if candidate.csys_project_profile == profile_key
        candidate = candidate.parent
      end
    end
    private_class_method :each_same_profile_ancestor
  end
end
