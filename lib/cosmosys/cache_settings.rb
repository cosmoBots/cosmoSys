module Cosmosys
  module CacheSettings
    DEFAULTS = {
      'invalidate_diagram_cache_on_boot' => '0'
    }.freeze

    def self.plugin_settings
      DEFAULTS.merge((Setting.plugin_cosmosys || {}).stringify_keys)
    end

    def self.invalidate_diagram_cache_on_boot?
      ActiveModel::Type::Boolean.new.cast(plugin_settings['invalidate_diagram_cache_on_boot'])
    end
  end
end
