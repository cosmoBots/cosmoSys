module Cosmosys
  class PendingRelationReconciler
    def initialize(root_project)
      @root = root_project.root
    end

    def call
      counts = Hash.new(0)
      Cosmosys::PendingRelation.pending.where(root_project_id: @root.id).find_each do |pending|
        targets = Issue.where(project_id: @root.self_and_descendants.select(:id))
                       .where('LOWER(csid) = ?', pending.external_csid.downcase)
                       .where.not(id: pending.local_issue_id).to_a
        if targets.one?
          relation = find_or_create_relation!(pending, targets.first)
          pending.update!(status: 'resolved', resolved_relation_id: relation.id)
          counts[:resolved] += 1
        elsif targets.many?
          counts[:ambiguous] += 1
        else
          counts[:pending] += 1
        end
      end
      counts
    end

    private

    def find_or_create_relation!(pending, target)
      from, to = pending.local_side == 'from' ? [pending.local_issue, target] : [target, pending.local_issue]
      IssueRelation.find_or_create_by!(issue_from: from, issue_to: to,
                                      relation_type: pending.relation_type) do |relation|
        relation.delay = pending.delay
      end
    end
  end
end
