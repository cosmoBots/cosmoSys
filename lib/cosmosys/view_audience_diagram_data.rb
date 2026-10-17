require 'set'
require_relative 'view_audience_selector'

module Cosmosys
  # Painter-facing view over the selector's hydrated ActiveRecord selection.
  # It filters diagram-specific visibility and builds hierarchy entries from
  # those same Issue and IssueRelation objects; it does not project/copy them.
  class ViewAudienceDiagramData
    attr_reader :selection, :issues, :relations, :boundary_issue_ids, :audience_issue_ids

    def self.for_project(project, scope:, user:, relation_types: ViewAudienceSelector::DEFAULT_RELATION_TYPES, selection_only: false)
      selection = PerformanceTrace.measure_with_sql('diagram.selection', category: :project, scope: scope, focus_id: project.id) do
        ViewAudienceSelector.for_project(
          project, scope: scope, user: user, relation_types: relation_types
        )
      end
      return selection if selection_only

      selection = PerformanceTrace.measure('diagram.selection_filter', category: :project, scope: scope) do
        diagram_selection(selection)
      end
      PerformanceTrace.measure('diagram.data_adapter', category: :project, scope: scope) do
        new(selection, focus_project_id: project.id)
      end
    end

    def self.diagram_selection(selection)
      audience_items = selection.audience_items.select(&:cosmosys_diagram_visible?)
      audience_ids = audience_items.map(&:id).to_set
      visible_items = selection.all_items.select(&:cosmosys_diagram_visible?).index_by(&:id)
      relations = (selection.relations + selection.boundary_relations).uniq(&:id).select do |relation|
        from = visible_items[relation.issue_from_id]
        to = visible_items[relation.issue_to_id]
        from && to && from.cosmosys_dependency_relation_visible?(relation.relation_type)
      end
      internal_relations = relations.select do |relation|
        audience_ids.include?(relation.issue_from_id) && audience_ids.include?(relation.issue_to_id)
      end
      boundary_relations = relations.reject { |relation| internal_relations.include?(relation) }
      relation_context_ids = boundary_relations.flat_map do |relation|
        [relation.issue_from_id, relation.issue_to_id].reject { |issue_id| audience_ids.include?(issue_id) }
      end.to_set

      ViewAudienceSelector::Selection.new(
        focus: selection.focus,
        category: selection.category,
        scope: selection.scope,
        projects: selection.projects,
        audience_items: audience_items,
        structural_context_items: selection.structural_context_items.select do |item|
          visible_items.key?(item.id) && !audience_ids.include?(item.id) && !relation_context_ids.include?(item.id)
        end,
        relations: internal_relations,
        boundary_relations: boundary_relations,
        relation_context_items: relation_context_ids.filter_map { |issue_id| visible_items[issue_id] }
      )
    end

    def self.for_item(issue, scope:, user:, relation_types: ViewAudienceSelector::DEFAULT_RELATION_TYPES, selection_only: false)
      selection = PerformanceTrace.measure_with_sql('diagram.selection', category: :item, scope: scope, focus_id: issue.id) do
        ViewAudienceSelector.for_item(
          issue, scope: scope, user: user, relation_types: relation_types
        )
      end
      return selection if selection_only

      selection = PerformanceTrace.measure('diagram.selection_filter', category: :item, scope: scope) do
        diagram_selection(selection)
      end
      PerformanceTrace.measure('diagram.data_adapter', category: :item, scope: scope) do
        new(selection, focus_project_id: issue.project_id)
      end
    end

    def self.project_boundary_issue_ids(issues, focus_project_id:)
      Array(issues).select { |issue| issue.project_id != focus_project_id }.map(&:id).to_set
    end

    def initialize(selection, focus_project_id:)
      @selection = selection
      @focus_project_id = focus_project_id
      @issues = selection.all_items
      @issue_ids = @issues.map(&:id).to_set
      @audience_issue_ids = selection.audience_item_ids
      @relations = (selection.relations + selection.boundary_relations).uniq(&:id).sort_by(&:id)
      @boundary_issue_ids = self.class.project_boundary_issue_ids(@issues, focus_project_id: focus_project_id)
    end

    def root_entries
      children_by_parent = issues.group_by(&:parent_issue_id)
      issues.reject { |issue| @issue_ids.include?(issue.parent_issue_id) }
            .sort_by { |issue| item_order(issue) }
            .map { |issue| build_entry(issue, children_by_parent) }
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

    def item_order(issue)
      [issue.csposition || 0, issue.lft || 0, issue.id]
    end

    def build_entry(issue, children_by_parent)
      children = Array(children_by_parent[issue.id]).sort_by { |child| item_order(child) }
      {
        issue: issue,
        boundary: @boundary_issue_ids.include?(issue.id),
        children: children.map { |child| build_entry(child, children_by_parent) }
      }
    end
  end
end
