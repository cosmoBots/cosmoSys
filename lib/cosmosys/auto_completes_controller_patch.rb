module Cosmosys
  module AutoCompletesControllerPatch
    def issues
      q = (params[:q] || params[:term]).to_s.strip
      return super if @project.blank? || q.blank? || !q.delete_prefix('#').include?('-')

      issues = Cosmosys::ItemResolver.new(project: @project, user: User.current).search(
        q,
        exclude_id: params[:issue_id],
        limit: 10
      )
      render json: format_issues_json(issues)
    end

    private

    def format_issues_json(issues)
      issues.map do |issue|
        {
          'id' => issue.id,
          'label' => "#{issue.tracker} ##{issue.csid}: #{issue.subject.to_s.truncate(255)}",
          'value' => issue.id
        }
      end
    end
  end
end
