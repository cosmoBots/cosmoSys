module Cosmosys
  module IssueRelationsControllerPatch
    private

    def relation_issues_to_id
      super.map do |reference|
        next reference unless Cosmosys::ItemResolver::CSID_PATTERN.match?(reference.to_s.strip.delete_prefix('#'))

        Cosmosys::ItemResolver.new(project: @issue.project, user: User.current).resolve(reference)&.id || ''
      end
    end
  end
end
