module Cosmosys
  module DependencySettings
    DEFAULTS = {
      'precedes_direction' => 'forward'
    }.freeze

    def self.plugin_settings
      DEFAULTS.merge((Setting.plugin_cosmosys || {}).stringify_keys)
    end

    def self.direction_for(relation_type)
      case relation_type.to_s
      when 'blocks'
        'forward'
      when 'precedes'
        normalize_direction(plugin_settings['precedes_direction'])
      else
        'forward'
      end
    end

    def self.normalize_direction(value)
      value.to_s == 'reverse' ? 'reverse' : 'forward'
    end
  end
end
