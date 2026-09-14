module Cosmosys
  class ReportPlaceholderDiagnostics
    Result = Struct.new(:code, :details, keyword_init: true)

    def initialize(project, user: User.current)
      @project = project
      @user = user
    end

    def call
      results = []
      results << Result.new(code: :documents_module_disabled) unless project.module_enabled?(:documents)
      results << Result.new(code: :cannot_add_items) unless user.allowed_to?(:add_issues, project)

      info_tracker = project.trackers.find_by(csys_key: 'cs_info')
      document_tracker = project.trackers.find_by(csys_key: 'cs_ref_doc')
      results << Result.new(code: :info_tracker_disabled) unless info_tracker
      results << Result.new(code: :document_tracker_disabled) unless document_tracker

      if document_tracker && document_tracker.cosmosys_item_kind_profile.report_placeholder_kinds.to_a.sort != ReportPlaceholder::DOCUMENT_KINDS.keys.sort
        results << Result.new(code: :document_profile_invalid, details: document_tracker.csys_item_kind)
      end

      placeholders = ReportPlaceholder.where(project_id: project.id).includes(:issue).index_by(&:kind)
      missing = ReportPlaceholder::DOCUMENT_KINDS.keys - placeholders.keys
      results << Result.new(code: :placeholders_missing, details: missing) if missing.any?
      invalid = placeholders.values.select { |placeholder| placeholder.issue.nil? || !placeholder.valid? }
      results << Result.new(code: :placeholders_invalid, details: invalid.map(&:kind)) if invalid.any?
      results
    end

    private

    attr_reader :project, :user
  end
end
