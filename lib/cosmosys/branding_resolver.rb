module Cosmosys
  class BrandingResolver
    Resolution = Data.define(:asset, :source_project, :diffuse_effect) do
      def custom? = asset.present?
    end

    def self.for(project)
      candidate = project
      while candidate
        asset = candidate.cosmosys_branding_asset
        return Resolution.new(asset: asset, source_project: candidate, diffuse_effect: asset.diffuse_effect?) if usable?(asset)

        candidate = candidate.parent
      end
      asset = Cosmosys::BrandingAsset.instance_asset
      return Resolution.new(asset: asset, source_project: nil, diffuse_effect: asset.diffuse_effect?) if usable?(asset)

      Resolution.new(asset: nil, source_project: nil, diffuse_effect: true)
    end

    def self.usable?(asset)
      asset&.attachment&.readable?
    end
    private_class_method :usable?
  end
end
