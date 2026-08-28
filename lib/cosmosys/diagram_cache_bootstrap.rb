module Cosmosys
  module DiagramCacheBootstrap
    mattr_accessor :boot_invalidation_ran, default: false

    def self.invalidate_all_if_enabled!
      return if boot_invalidation_ran

      self.boot_invalidation_ran = true
      return unless Cosmosys::CacheSettings.invalidate_diagram_cache_on_boot?
      return unless defined?(Cosmosys::Diagram)
      return unless Cosmosys::Diagram.table_exists?

      Cosmosys::Diagram.update_all(state: 'obsolete', updated_at: Time.current)
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
      true
    end
  end
end
