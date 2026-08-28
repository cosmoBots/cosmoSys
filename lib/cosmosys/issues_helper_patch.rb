module Cosmosys
  module IssuesHelperPatch
    def issue_heading(issue)
      return super unless issue.respond_to?(:cosmosys_display_ref)

      h("#{issue.tracker} ##{issue.id} | #{issue.cosmosys_display_ref}")
    end

    def link_to_new_subtask(issue)
      profile = issue.cosmosys_item_kind
      return nil unless profile.can_have_children
      if issue.leaf? && profile.can_split
        return link_to(l(:label_cosmosys_split_task), issue_cosmosys_split_path(issue), class: 'icon icon-split')
      end

      super
    end
  end
end
