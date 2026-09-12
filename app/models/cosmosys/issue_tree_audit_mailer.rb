module Cosmosys
  class IssueTreeAuditMailer < Mailer
    def anomalies(user, summary)
      @summary = summary
      @lines = summary.fetch(:results).map do |row|
        problem = row.fetch(:problem)
        "- #{row.fetch(:root_project)}: #{problem.fetch(:reason)} " \
          "(item ##{problem.fetch(:issue_id)}, CSID #{problem[:csid].presence || '-'})"
      end

      mail to: user,
           subject: "[#{Setting.app_title}] #{l(:mail_subject_cosmosys_issue_tree_audit)}"
    end
  end
end
