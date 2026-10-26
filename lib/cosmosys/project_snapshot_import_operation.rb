require 'fileutils'
require 'json'
require 'securerandom'
require 'tempfile'
require 'time'

module Cosmosys
  # Import progress lives outside the materializer's database transaction so
  # other requests can observe it before commit. Like uploaded snapshot stages,
  # it is private, bounded temporary filesystem state, shared by Rails workers.
  class ProjectSnapshotImportOperation
    LIFETIME = 7.days
    UNSCOPED = Object.new.freeze
    TOKEN_PATTERN = /\A[A-Za-z0-9_-]{43}\z/
    attr_reader :token, :data

    def self.root
      Rails.root.join('tmp', 'cosmosys', 'snapshot-import-operations')
    end

    def self.create(path, user:, project:, attributes:, confirmed_plan:)
      token = SecureRandom.urlsafe_base64(32)
      directory = root.join(token)
      FileUtils.mkdir_p(directory, mode: 0o700)
      FileUtils.cp(path, directory.join('package.csys'))
      File.chmod(0o600, directory.join('package.csys'))
      operation = new(token, {
        'user_id' => user.id, 'project_id' => project&.id,
        'attributes' => attributes.to_h.deep_stringify_keys, 'confirmed_plan' => confirmed_plan,
        'created_at' => Time.now.utc.iso8601, 'state' => 'queued',
        'summary' => { 'progress' => 0, 'progress_phase' => 'queued' }
      })
      operation.update!({})
      operation
    rescue StandardError
      FileUtils.remove_entry(directory, true) if directory && File.directory?(directory)
      raise
    end

    def self.find(token, user: nil, project: UNSCOPED)
      return unless token.to_s.match?(TOKEN_PATTERN)

      data = JSON.parse(File.read(root.join(token, 'status.json')))
      return if user && data['user_id'] != user.id
      return if !project.equal?(UNSCOPED) && data['project_id'] != project&.id
      return if Time.parse(data.fetch('created_at')) < LIFETIME.ago

      new(token, data)
    rescue Errno::ENOENT, JSON::ParserError, KeyError, ArgumentError
      nil
    end

    def self.recent(user:, project:)
      return [] unless root.directory?

      Dir.children(root).filter_map { |token| find(token, user: user, project: project) }
         .sort_by { |operation| operation.data.fetch('created_at') }.reverse.first(10)
    end

    def self.cleanup_expired!
      return unless root.directory?

      Dir.children(root).each do |token|
        next unless token.match?(TOKEN_PATTERN)
        directory = root.join(token)
        next unless directory.directory? && directory.mtime < LIFETIME.ago

        File.open(directory.join('execution.lock'), 'a', 0o600) do |lock|
          FileUtils.remove_entry(directory, true) if lock.flock(File::LOCK_EX | File::LOCK_NB)
        end
      rescue Errno::ENOENT
        next
      end
    end

    def initialize(token, data)
      @token = token
      @data = data
    end

    def state
      data.fetch('state')
    end

    def summary
      data.fetch('summary')
    end

    def package_path
      self.class.root.join(token, 'package.csys')
    end

    def update!(attributes)
      data.merge!(attributes.stringify_keys)
      data['updated_at'] = Time.now.utc.iso8601
      directory = self.class.root.join(token)
      Tempfile.create(['status-', '.json'], directory) do |file|
        file.write(JSON.generate(data))
        file.flush
        File.rename(file.path, directory.join('status.json'))
      end
    end

    def with_execution_lock
      File.open(self.class.root.join(token, 'execution.lock'), 'a', 0o600) do |lock|
        return unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        # A retried or duplicate delivery must never materialize twice.
        @data = self.class.find(token).data
        yield if state == 'queued'
      end
    end

    def release_package!
      FileUtils.rm_f(package_path)
    end

    # Only the execution lock proves a running worker has stopped. A slow
    # phase or old timestamp is not evidence of interruption.
    def detect_interruption!
      return self unless state == 'running'

      with_idle_lock do
        if state == 'running'
          update!(state: 'interrupted', summary: summary.merge(
            'progress_phase' => 'interrupted',
            'error' => I18n.t(:text_cosmosys_snapshot_interrupted)
          ))
        end
      end
      self
    end

    # Explicitly withdraw a queued delivery before copying its package to a
    # fresh preflight. A delayed duplicate job will then be a no-op.
    def prepare_retry!
      with_idle_lock do
        next unless %w[queued running interrupted failed].include?(state) && package_path.file?

        update!(state: 'interrupted', summary: summary.merge(
          'progress_phase' => 'interrupted', 'error' => I18n.t(:text_cosmosys_snapshot_interrupted)
        ))
        yield package_path
      end
    end

    private

    def with_idle_lock
      File.open(self.class.root.join(token, 'execution.lock'), 'a', 0o600) do |lock|
        return unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        fresh = self.class.find(token)
        return unless fresh

        @data = fresh.data
        yield
      end
    end
  end
end
