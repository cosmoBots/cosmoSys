module Cosmosys
  module ProjectCopyReferenceRegistry
    mattr_accessor :attributes, default: []

    def self.register(attribute)
      self.attributes = (attributes + [attribute.to_s]).uniq.freeze
    end
  end
end
