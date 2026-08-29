module Cosmosys
  class ReportPlaceholderInstaller
    DEFAULT_SUBJECTS = {
      'reference_documents' => :label_cosmosys_placeholder_reference_documents,
      'applicable_documents' => :label_cosmosys_placeholder_applicable_documents,
      'compliance_documents' => :label_cosmosys_placeholder_compliance_documents
    }.freeze

    Result = Struct.new(:created, :existing, :section, keyword_init: true)

    def initialize(project, user: User.current)
      @project = project
      @user = user
    end

    def call
      @project.with_cosmosys_locale { install }
    end

    private

    def install
      placeholder_tracker = @project.trackers.find_by(csys_key: 'cs_ref_doc') || raise(ActiveRecord::RecordNotFound, 'csRefDoc tracker is not enabled')
      section_tracker = @project.trackers.find_by(csys_key: 'cs_info') || raise(ActiveRecord::RecordNotFound, 'csInfo tracker is not enabled')
      existing = Cosmosys::ReportPlaceholder.where(project_id: @project.id).index_by(&:kind)
      created_placeholders = []
      section = nil

      Issue.transaction do
        section = find_or_create_section!(section_tracker)

        DEFAULT_SUBJECTS.each do |kind, subject_key|
          issue = existing[kind]&.issue || create_placeholder!(placeholder_tracker, kind, subject_key, created_placeholders)
          move_below_section!(issue, section)
        end
      end

      Result.new(created: created_placeholders, existing: existing.values, section: section)
    end

    def find_or_create_section!(tracker)
      existing_issues = Cosmosys::ReportPlaceholder.where(project_id: @project.id).includes(:issue).map(&:issue)
      common_parent = existing_issues.map(&:parent).compact.uniq(&:id).one? ? existing_issues.first&.parent : nil
      return common_parent if common_parent&.cosmosys_item_kind_key == 'info'

      issue = Issue.new(
        project: @project,
        tracker: tracker,
        status: tracker.default_status || IssueStatus.order(:position, :id).first!,
        author: @user,
        subject: I18n.t(:label_cosmosys_related_documents),
        csposition: next_root_position
      )
      issue.notify = false
      issue.save!
      issue
    end

    def create_placeholder!(tracker, kind, subject_key, created)
      issue = Issue.new(
        project: @project,
        tracker: tracker,
        status: tracker.default_status || IssueStatus.order(:position, :id).first!,
        author: @user,
        subject: I18n.t(subject_key)
      )
      issue.csys_report_placeholder_kind = kind
      issue.notify = false
      issue.save!
      created << issue
      issue
    end

    def move_below_section!(issue, section)
      issue.reload
      section.reload
      return if issue.parent_id == section.id

      issue.parent_issue_id = section.id
      issue.csposition = next_child_position(section)
      issue.notify = false
      issue.save!
    end

    def next_root_position
      Issue.where(project_id: @project.id, parent_id: nil).maximum(:csposition).to_i + 1
    end

    def next_child_position(section)
      Issue.where(project_id: @project.id, parent_id: section.id).maximum(:csposition).to_i + 1
    end
  end
end
