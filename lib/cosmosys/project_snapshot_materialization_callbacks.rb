module Cosmosys
  # Extension point for plugins that derive state from a fully materialized
  # snapshot. Callbacks run inside the materializer transaction, after item
  # identities, references, hierarchy and relations have been restored.
  class ProjectSnapshotMaterializationCallbacks
    class << self
      def register(key, &callback)
        raise ArgumentError, 'a callback block is required' unless callback

        callbacks[key.to_sym] = callback
      end

      def run(**context)
        callbacks.each_value { |callback| callback.call(context) }
      end

      private

      def callbacks
        @callbacks ||= {}
      end
    end
  end
end
