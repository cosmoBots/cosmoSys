require 'digest'
require 'fileutils'
require 'securerandom'

module Cosmosys
  # Small, shared-filesystem cancellation signals. Nothing is added to the
  # database or the domain transaction. Tokens are random browser capabilities,
  # additionally scoped to the current user, never process IDs supplied by users.
  module RenderCancellation
    class Cancelled < StandardError; end
    TOKEN_PATTERN = /\A[0-9a-f]{32}\z/
    THREAD_KEY = :cosmosys_render_cancellation
    RETENTION = 3600
    MAX_SIGNALS = 4096

    def self.root
      Rails.root.join('tmp', 'cosmosys', 'render-cancellation')
    end

    def self.key(token, user)
      Digest::SHA256.hexdigest("#{user&.id}:#{token}") if token.to_s.match?(TOKEN_PATTERN)
    end

    def self.cancel(token, user:)
      identifier = key(token, user)
      return false unless identifier

      FileUtils.mkdir_p(root.join('signals'), mode: 0o700)
      # A tombstone also handles an abort arriving before a queued HTTP request
      # reaches Rails. It expires; an old token must never be reused by clients.
      File.open(root.join('signals.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        path = root.join('signals', identifier)
        return false if !path.exist? && Dir.children(root.join('signals')).size >= MAX_SIGNALS

        FileUtils.touch(path)
      end
      true
    end

    def self.current
      Thread.current[THREAD_KEY]
    end

    def self.with_request(token, user:)
      previous = current
      Thread.current[THREAD_KEY] = Context.new(key(token, user))
      check!
      yield
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def self.check!(shared: true)
      current&.check!(shared: shared)
    end

    def self.with_consumers(identity)
      previous = current
      Thread.current[THREAD_KEY] ||= Context.new(nil)
      current.with_consumers(identity) { yield }
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    # Opportunistic cleanup; signal count is bounded separately and live
    # members are protected by flock.
    # Workers and web servers must share this tmp directory, like snapshot jobs.
    def self.cleanup!
      return unless root.directory?

      Dir.glob(root.join('{signals,members}', '*').to_s).each do |path|
        next unless File.mtime(path) < Time.now - RETENTION
        File.open(path, 'r') do |file|
          File.unlink(path) if file.flock(File::LOCK_EX | File::LOCK_NB)
        end
      rescue Errno::ENOENT
        next
      end
    end

    class Context
      def initialize(key)
        @key = key
        @group = nil
      end

      def check!(shared: true)
        return unless @key && File.exist?(RenderCancellation.root.join('signals', @key))
        return if shared && @group && other_consumer?

        raise Cancelled, 'Diagram request has no remaining consumer'
      end

      def with_consumers(identity)
        previous = @group
        @group = Digest::SHA256.hexdigest(identity)
        directory = RenderCancellation.root.join('members')
        FileUtils.mkdir_p(directory, mode: 0o700)
        member = directory.join("#{@group}-#{@key || 'direct'}-#{SecureRandom.hex(8)}")
        File.open(member, File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          yield
        ensure
          FileUtils.rm_f(member)
        end
      ensure
        @group = previous
      end

      private

      def other_consumer?
        Dir.glob(RenderCancellation.root.join('members', "#{@group}-*").to_s).any? do |path|
          consumer = File.basename(path).split('-')[1]
          next false if consumer != 'direct' && File.exist?(RenderCancellation.root.join('signals', consumer))

          File.open(path, 'r') { |file| !file.flock(File::LOCK_EX | File::LOCK_NB) }
        rescue Errno::ENOENT
          false
        end
      end
    end
  end
end
