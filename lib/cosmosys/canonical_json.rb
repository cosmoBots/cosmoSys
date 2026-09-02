require 'json'

module Cosmosys
  module CanonicalJson
    module_function

    def generate(value)
      JSON.generate(normalize(value))
    end

    def normalize(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), result| result[key.to_s] = normalize(child) }
             .sort.to_h
      when Array
        value.map { |child| normalize(child) }
      when Time, DateTime
        value.utc.iso8601(6)
      when Date
        value.iso8601
      when BigDecimal
        value.to_s('F')
      else
        value
      end
    end
  end
end
