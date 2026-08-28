require 'json'

module Cosmosys
  module PerformanceTrace
    module_function

    def measure(event, attributes = {})
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      emit(event, attributes.merge(status: 'ok'), started)
      result
    rescue StandardError
      emit(event, attributes.merge(status: 'error'), started)
      raise
    end

    def emit(event, attributes, started)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      Rails.logger.info({ cosmosys_performance: event, duration_ms: duration_ms }.merge(attributes).to_json)
    end
  end
end
