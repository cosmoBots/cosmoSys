require 'set'
require_relative 'view_audience_model'
require_relative 'view_audience_selector'

module Cosmosys
  # Bridges the selector's hydrated ActiveRecord selection to the existing
  # Graphviz painters. The portable model captures the selected graph for
  # traversal; selected records are reused for established presentation
  # methods without reloading items or relations from the database.
  class ViewAudienceDiagramData
    attr_reader :model, :issues, :relations, :boundary_issue_ids, :audience_issue_ids

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
      model = PerformanceTrace.measure('diagram.model_projection', category: :project, scope: scope) do
        ViewAudienceModel.from_selection(selection)
      end
      PerformanceTrace.measure('diagram.data_adapter', category: :project, scope: scope) do
        new(
          model,
          focus_project_id: project.id,
          selected_issues: selection.all_items,
          selected_relations: selection.relations + selection.boundary_relations
        )
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
      model = PerformanceTrace.measure('diagram.model_projection', category: :item, scope: scope) do
        ViewAudienceModel.from_selection(selection)
      end
      PerformanceTrace.measure('diagram.data_adapter', category: :item, scope: scope) do
        new(
          model,
          focus_project_id: issue.project_id,
          selected_issues: selection.all_items,
          selected_relations: selection.relations + selection.boundary_relations
        )
      end
    end

    def self.project_boundary_issue_ids(issues, focus_project_id:)
      Array(issues).select { |issue| issue.project_id != focus_project_id }.map(&:id).to_set
    end

    def initialize(model, focus_project_id:, selected_issues:, selected_relations:)
      @model = model
      @focus_project_id = focus_project_id
      hydrate_selected_items(selected_issues)
      @relations = Array(selected_relations).sort_by(&:id)
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

    def hydrate_selected_items(selected_issues)
      @issues_by_source_id = Array(selected_issues).index_by(&:id)
      @model_items = model.all_items.select { |item| @issues_by_source_id.key?(item.source_id) }
      @issues_by_model_id = @model_items.to_h do |item|
        [item.id, @issues_by_source_id.fetch(item.source_id)]
      end
      @issues = @issues_by_model_id.values.uniq(&:id)
      @model_item_ids = @model_items.map(&:id).to_set
      @audience_issue_ids = model.audience_items.filter_map do |item|
        @issues_by_model_id[item.id]&.id
      end.to_set
      @boundary_issue_ids = self.class.project_boundary_issue_ids(@issues, focus_project_id: @focus_project_id)
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
