require 'set'
require_relative 'view_audience_model'
require_relative 'view_audience_selector'

module Cosmosys
  # Bridges the selector's ActiveRecord-free diagram model to the existing
  # Graphviz painters. The selected model is the source of truth for nodes,
  # hierarchy and relations; ActiveRecord records are looked up only to reuse
  # the established presentation methods while painting.
  class ViewAudienceDiagramData
    attr_reader :model, :issues, :relations, :boundary_issue_ids, :audience_issue_ids

    def self.for_project(project, scope:, user:, relation_types: ViewAudienceSelector::DEFAULT_RELATION_TYPES)
      source = source_model(project, user: user, relation_types: relation_types)
      new(
        source.for_project(project.identifier, scope: scope, relation_types: relation_types),
        focus_project_id: project.id,
        user: user
      )
    end

    def self.for_item(issue, scope:, user:, relation_types: ViewAudienceSelector::DEFAULT_RELATION_TYPES, source_model: nil)
      model = if source_model
                item_id = issue.csid.presence || "item:#{issue.id}"
                source_model.for_item(item_id, scope: scope, relation_types: relation_types)
              elsif scope.to_sym == :node_and_descendants
                # The ordinary combined view uses the generic boundary-aware
                # selector: local descendants plus only directly incident
                # relations. This keeps a foreign endpoint visible as context
                # without following relations from that endpoint.
                ViewAudienceSelector.for_item(
                  issue, scope: scope, user: user, relation_types: relation_types
                ).diagram_model
              else
                source = self.source_model(issue.project, user: user, relation_types: relation_types)
                item_id = issue.csid.presence || "item:#{issue.id}"
                source.for_item(item_id, scope: scope, relation_types: relation_types)
              end

      new(model, focus_project_id: issue.project_id, user: user)
    end

    def self.source_model(project, user:, relation_types:, expand_relation_graph: false)
      tree_projects = project.root.self_and_descendants.to_a.select { |candidate| candidate.visible?(user) }
      tree_project_ids = tree_projects.map(&:id)
      tree_issues = Issue.visible(user).where(project_id: tree_project_ids)
                         .includes(:project, :parent, :tracker, :status, :priority).to_a
                         .select(&:cosmosys_diagram_visible?)
      tree_issue_ids = tree_issues.map(&:id)
      issues_by_id = tree_issues.index_by(&:id)
      relations_by_id = {}
      frontier_ids = tree_issue_ids.dup
      visited_issue_ids = tree_issue_ids.to_set
      while frontier_ids.any?
        batch = IssueRelation.where(relation_type: Array(relation_types).map(&:to_s))
                             .where('issue_from_id IN (:ids) OR issue_to_id IN (:ids)', ids: frontier_ids)
                             .includes(issue_from: [:project, :tracker, :status, :priority], issue_to: [:project, :tracker, :status, :priority])
                             .order(:id).to_a.select do |relation|
          from = relation.issue_from
          to = relation.issue_to
          from&.visible?(user) && to&.visible?(user) &&
            from.cosmosys_diagram_visible? && to.cosmosys_diagram_visible? &&
            from.cosmosys_dependency_relation_visible?(relation.relation_type)
        end
        batch.each { |relation| relations_by_id[relation.id] = relation }
        break unless expand_relation_graph

        fresh_ids = batch.flat_map { |relation| [relation.issue_from_id, relation.issue_to_id] }
                         .uniq.reject { |issue_id| visited_issue_ids.include?(issue_id) }
        break if fresh_ids.empty?

        fresh_issues = Issue.visible(user).where(id: fresh_ids)
                            .includes(:project, :parent, :tracker, :status, :priority).to_a
                            .select(&:cosmosys_diagram_visible?)
        issues_by_id.merge!(fresh_issues.index_by(&:id))
        visited_issue_ids.merge(fresh_issues.map(&:id))
        frontier_ids = fresh_issues.map(&:id)
      end
      # Keep structural context for foreign relation endpoints (for example,
      # the project-owned container above the first boundary node). Do not add
      # these parents to the relation frontier: hierarchy context must not
      # cause the dependency walk to fan out into their siblings.
      parent_frontier_ids = issues_by_id.values.filter_map(&:parent_id).uniq
      visited_parent_ids = issues_by_id.keys.to_set
      while parent_frontier_ids.any?
        fresh_parent_ids = parent_frontier_ids.reject { |issue_id| visited_parent_ids.include?(issue_id) }
        break if fresh_parent_ids.empty?

        parents = Issue.visible(user).where(id: fresh_parent_ids)
                       .includes(:project, :parent, :tracker, :status, :priority).to_a
                       .select(&:cosmosys_diagram_visible?)
        break if parents.empty?

        issues_by_id.merge!(parents.index_by(&:id))
        visited_parent_ids.merge(parents.map(&:id))
        parent_frontier_ids = parents.filter_map(&:parent_id).uniq
      end
      relations = relations_by_id.values.sort_by(&:id)
      projects = (tree_projects + issues_by_id.values.map(&:project)).compact.uniq(&:id)
      ViewAudienceModel.from_records(
        projects: projects,
        issues: issues_by_id.values,
        relations: relations,
        focus_id: project.identifier,
        category: :source,
        scope: :all
      )
    end

    def self.project_boundary_issue_ids(issues, focus_project_id:)
      Array(issues).select { |issue| issue.project_id != focus_project_id }.map(&:id).to_set
    end

    def initialize(model, focus_project_id:, user:)
      @model = model
      @focus_project_id = focus_project_id
      @user = user
      hydrate_items
      hydrate_relations
    end

    def root_entries
      children_by_parent = model_items.group_by(&:parent_id)
      model_items.reject { |item| model_item_ids.include?(item.parent_id) }
                 .sort_by { |item| item_order(item) }
                 .map { |item| build_entry(item, children_by_parent) }
    end

    def component
      involved_ids = relations.flat_map { |relation| [relation.issue_from_id, relation.issue_to_id] }.to_set
      {
        issues: issues.select { |issue| involved_ids.include?(issue.id) }.sort_by(&:id),
        relations: relations,
        boundary_issue_ids: boundary_issue_ids & involved_ids
      }
    end

    private

    def hydrate_items
      records = model.all_items
      source_ids = records.filter_map(&:source_id).uniq
      loaded = Issue.visible(@user).where(id: source_ids)
                    .includes(:project, :tracker, :parent)
                    .to_a.select(&:cosmosys_diagram_visible?)
      @issues_by_source_id = loaded.index_by(&:id)
      @model_items = records.select { |item| @issues_by_source_id.key?(item.source_id) }
      @issues_by_model_id = @model_items.to_h { |item| [item.id, @issues_by_source_id.fetch(item.source_id)] }
      @issues = @issues_by_model_id.values.uniq(&:id)
      @model_item_ids = @model_items.map(&:id).to_set
      @audience_issue_ids = model.audience_items.filter_map do |item|
        @issues_by_model_id[item.id]&.id
      end.to_set
      # Relation context is not synonymous with a project boundary: a selector
      # may add same-project predecessors/successors as context. The painter's
      # `+` marker means only that this item belongs to a different project
      # than the focus item/project.
      @boundary_issue_ids = self.class.project_boundary_issue_ids(@issues, focus_project_id: @focus_project_id)
    end

    def hydrate_relations
      source_ids = model.all_relations.filter_map(&:source_id).map(&:to_i).uniq
      return @relations = [] if source_ids.empty?

      @relations = IssueRelation.where(id: source_ids).includes(:issue_from, :issue_to).order(:id).to_a.select do |relation|
        from = @issues_by_source_id[relation.issue_from_id]
        to = @issues_by_source_id[relation.issue_to_id]
        from && to && from.cosmosys_dependency_relation_visible?(relation.relation_type)
      end
    end

    def model_items
      @model_items
    end

    def model_item_ids
      @model_item_ids
    end

    def item_order(item)
      issue = @issues_by_model_id.fetch(item.id)
      [issue.csposition || 0, issue.lft || 0, issue.id]
    end

    def build_entry(item, children_by_parent)
      issue = @issues_by_model_id.fetch(item.id)
      children = Array(children_by_parent[item.id]).sort_by { |child| item_order(child) }
      {
        issue: issue,
        boundary: @boundary_issue_ids.include?(issue.id),
        children: children.map { |child| build_entry(child, children_by_parent) }
      }
    end
  end
end
