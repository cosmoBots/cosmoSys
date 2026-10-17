require 'json'

module Cosmosys
  module PerformanceTrace
    module_function
    AGGREGATE_KEY = :cosmosys_performance_aggregates

    def measure(event, attributes = {})
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      record_or_emit(event, attributes.merge(status: 'ok'), started)
      result
    rescue StandardError
      record_or_emit(event, attributes.merge(status: 'error'), started)
      raise
    end

    # Collects many small measurements (for example one validity check per
    # item) into a single log record, avoiding one log line per model object.
    def aggregate(event, attributes = {})
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      aggregate = {
        event: event, count: 0, total_duration_ms: 0.0, max_duration_ms: 0.0,
        errors: 0, item_kinds: Hash.new(0), item_kind_duration_ms: Hash.new(0.0)
      }
      stack = Thread.current[AGGREGATE_KEY] ||= []
      stack << aggregate
      result = yield
      result
    rescue StandardError
      aggregate[:status] = 'error'
      raise
    ensure
      if aggregate
        stack&.pop
        Thread.current[AGGREGATE_KEY] = nil if stack&.empty?
        report(event, attributes.merge(
          duration_ms: aggregate[:total_duration_ms].round(1),
          status: aggregate[:status] || 'ok',
          count: aggregate[:count],
          total_duration_ms: aggregate[:total_duration_ms].round(1),
          max_duration_ms: aggregate[:max_duration_ms].round(1),
          errors: aggregate[:errors],
          item_kinds: aggregate[:item_kinds],
          item_kind_duration_ms: aggregate[:item_kind_duration_ms].transform_values { |duration| duration.round(1) }
        ))
      end
    end

    def measure_with_sql(event, attributes = {})
      trace_attributes = attributes.dup
      trace_attributes[:sql_queries] = 0
      trace_attributes[:sql_cached_queries] = 0
      trace_attributes[:sql_duration_ms] = 0.0
      subscriber = lambda do |_name, started, finished, _id, payload|
        next if payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)

        trace_attributes[:sql_queries] += 1
        trace_attributes[:sql_cached_queries] += 1 if payload[:cached]
        trace_attributes[:sql_duration_ms] += ((finished - started) * 1000)
      end
      result = ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        measure(event, trace_attributes) { yield }
      end
      trace_attributes[:sql_duration_ms] = trace_attributes[:sql_duration_ms].round(1)
      result
    end

    def report(event, attributes = {})
      Rails.logger.info({ cosmosys_performance: event }.merge(attributes).to_json)
    end

    def emit(event, attributes, started)
      duration_ms = elapsed_ms(started).round(1)
      Rails.logger.info({ cosmosys_performance: event, duration_ms: duration_ms }.merge(attributes).to_json)
    end

    def elapsed_ms(started)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    end

    def record_or_emit(event, attributes, started)
      aggregate = Array(Thread.current[AGGREGATE_KEY]).reverse.find { |entry| entry[:event] == event }
      unless aggregate
        emit(event, attributes, started)
        return
      end

      duration_ms = elapsed_ms(started)
      aggregate[:count] += 1
      aggregate[:total_duration_ms] += duration_ms
      aggregate[:max_duration_ms] = [aggregate[:max_duration_ms], duration_ms].max
      aggregate[:errors] += 1 if attributes[:status] == 'error'
      if attributes[:item_kind]
        item_kind = attributes[:item_kind].to_s
        aggregate[:item_kinds][item_kind] += 1
        aggregate[:item_kind_duration_ms][item_kind] += duration_ms
      end
    end
  end
end
