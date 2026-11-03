require_relative 'view_audience_diagram_data'

module Cosmosys
  # Model windows differ from contextual combined diagrams. Reuse discovery,
  # permissions and boundary traversal, without adding ancestor boxes for layout.
  class ModelYamlSelection
    ITEM_SCOPES = %i[node node_and_descendants project node_ancestors_and_descendants
                     node_and_descendants_with_successors node_and_descendants_with_predecessors].freeze
    PROJECT_SCOPES = ViewAudienceSelector::PROJECT_SCOPES
    ITEM_SELECTOR_SCOPES = {
      node: :node_and_descendants,
      node_and_descendants: :node_and_descendants_across_projects
    }.freeze

    def self.call(source, scope:, user: User.current)
      category = source.is_a?(Issue) ? :item : :project
      scopes = category == :item ? ITEM_SCOPES : PROJECT_SCOPES
      raise ViewAudienceSelector::InvalidScope, 'Invalid model window scope' unless scopes.map(&:to_s).include?(scope.to_s)

      scope = scope.to_sym
      options = {scope: scope, user: user, include_structural_ancestors: false}
      if category == :item && scope == :project
        ViewAudienceDiagramData.for_project(source.project, **options)
      elsif category == :item
        ViewAudienceDiagramData.for_item(source, **options.merge(scope: ITEM_SELECTOR_SCOPES.fetch(scope, scope)))
      else
        ViewAudienceDiagramData.for_project(source, **options)
      end
    end
  end
end
