# frozen_string_literal: true

module Cosmosys
  # Runs registered, idempotent reconciliations when a cosmoSys contract changes.
  # Individual consolidators own their scope and fingerprint.
  class ConsolidationService
    class << self
      def register(key, operation = nil, &block)
        normalized_key = key.to_s.strip
        raise ArgumentError, 'consolidation key is required' if normalized_key.empty?
        raise ArgumentError, 'provide either an operation or a block' if operation && block

        callable = operation || block
        raise ArgumentError, 'consolidation operation must respond to call' unless callable.respond_to?(:call)

        operations[normalized_key] = callable
      end

      def call(only: nil)
        selected = if only
                     Array(only).map(&:to_s).to_h do |key|
                       [key, operations.fetch(key) { raise ArgumentError, "unknown consolidation #{key}" }]
                     end
                   else
                     operations.sort.to_h
                   end

        selected.each_with_object({}) do |(key, operation), results|
          results[key] = operation.call
        end
      end

      # Rails loads the application while running tasks such as db:migrate and
      # rails runner too. Restrict automatic reconciliation to a web-server
      # boot, which follows the normal deployment step that applies migrations.
      def run_at_server_start!(server_process: web_server_process?)
        return { status: :skipped_non_server } unless server_process

        call
      end

      def registered_keys
        operations.keys.sort
      end

      private

      def web_server_process?
        return true if defined?(Rails::Server)

        # Redmine's container entrypoint execs Puma directly, so Rails::Server
        # is not necessarily loaded when plugin after_initialize callbacks run.
        File.basename($PROGRAM_NAME).match?(/\A(?:puma|unicorn|passenger|thin)(?:\z|-)/)
      end

      def operations
        @operations ||= {}
      end
    end
  end
end
