module Cosmosys
  class ProjectCopyContext
    KEY = :cosmosys_project_copy_context
    MODES = %w[clean faithful].freeze

    attr_reader :source_project, :user, :mode, :selected_parts, :profile_key,
                :issue_map, :document_map, :summary
    attr_accessor :destination_project

    def self.current
      ActiveSupport::IsolatedExecutionState[KEY]
    end

    def self.with(context)
      previous = current
      ActiveSupport::IsolatedExecutionState[KEY] = context
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[KEY] = previous
    end

    def initialize(source_project:, user:, mode:, selected_parts:, profile_key: nil, archive: false)
      @source_project = source_project
      @user = user
      @mode = MODES.include?(mode.to_s) ? mode.to_s : 'clean'
      @selected_parts = Array(selected_parts).map(&:to_s)
      @profile_key = Cosmosys::ProjectProfileRegistry.normalize_key(profile_key.presence || source_project.cosmosys_project_profile)
      @archive = ActiveModel::Type::Boolean.new.cast(archive)
      @issue_map = {}
      @document_map = {}
      @summary = {}
    end

    def archive?
      mode == 'faithful' && @archive
    end

    def copying?(part)
      selected_parts.include?(part.to_s)
    end

    def register_issue(source_id, issue)
      issue_map[source_id.to_i] = issue
    end

    def register_document(source_id, document)
      document_map[source_id.to_i] = document
    end
  end

  class ProjectCopyError < StandardError; end
end
