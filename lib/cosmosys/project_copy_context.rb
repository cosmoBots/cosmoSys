module Cosmosys
  class ProjectCopyContext
    KEY = :cosmosys_project_copy_context
    MODES = %w[clean faithful].freeze
    IDENTITY_MODES = %w[new preserve].freeze

    attr_reader :source_project, :user, :mode, :identity_mode, :selected_parts, :profile_key,
                :issue_map, :document_map, :deferred_issue_references, :summary
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

    def initialize(source_project:, user:, mode:, selected_parts:, profile_key: nil, archive: false,
                   identity_mode: nil)
      @source_project = source_project
      @user = user
      @mode = MODES.include?(mode.to_s) ? mode.to_s : 'clean'
      default_identity_mode = @mode == 'faithful' ? 'preserve' : 'new'
      @identity_mode = IDENTITY_MODES.include?(identity_mode.to_s) ? identity_mode.to_s : default_identity_mode
      @selected_parts = Array(selected_parts).map(&:to_s)
      @profile_key = Cosmosys::ProjectProfileRegistry.normalize_key(profile_key.presence || source_project.csys_project_profile)
      @archive = ActiveModel::Type::Boolean.new.cast(archive)
      @issue_map = {}
      @document_map = {}
      @deferred_issue_references = {}
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

    def defer_issue_reference(source_issue_id, attribute, referenced_issue_id)
      deferred_issue_references[source_issue_id.to_i] ||= {}
      deferred_issue_references[source_issue_id.to_i][attribute.to_s] = referenced_issue_id&.to_i
    end

    def register_document(source_id, document)
      document_map[source_id.to_i] = document
    end
  end

  class ProjectCopyError < StandardError; end
end
