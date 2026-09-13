module Cosmosys
  module PresentationTextRegistry
    @resolvers = {}

    module_function

    def register(key, &resolver)
      raise ArgumentError, 'resolver block required' unless resolver

      @resolvers[key.to_s] = resolver
    end

    def resolve(text, project:, user:, formatter: nil)
      @resolvers.values.reduce(text.to_s) do |current, resolver|
        resolver.call(current, project: project, user: user, formatter: formatter)
      end
    end
  end
end
