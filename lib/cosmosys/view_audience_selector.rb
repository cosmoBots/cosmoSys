require 'set'
require_relative 'render_cancellation'

module Cosmosys
  # Selects the model content that belongs to a view, independently of how a
  # particular consumer (diagram, PORIS viewer, preview, ...) renders it.
  #
  # `audience_items` are the selected content. Structural ancestors and direct
  # relation endpoints outside that audience are returned separately as
  # context; neither kind of context is recursively expanded.
  class ViewAudienceSelector
    PROJECT_SCOPES = %i[
      project
      project_and_ancestors
      project_and_descendants
      project_ancestors_and_descendants
    ].freeze

    ITEM_SCOPES = %i[
      node
      node_and_descendants
      project
      node_and_descendants_across_projects
      node_ancestors_and_descendants
      node_and_descendants_with_successors
      node_and_descendants_with_predecessors
    ].freeze

    DEFAULT_RELATION_TYPES = %w[blocks precedes relates].freeze

    Selection = Struct.new(
      :focus,
      :category,
      :scope,
      :projects,
      :audience_items,
      :structural_context_items,
      :relations,
      :boundary_relations,
      :relation_context_items,
      keyword_init: true
    ) do
      def audience_item_ids
        audience_items.map(&:id).to_set
      end

      def context_items
        (structural_context_items + relation_context_items).uniq(&:id)
      end

      def context_item_ids
        context_items.map(&:id).to_set
      end

      def all_items
        (audience_items + context_items).uniq(&:id)
      end

      def all_item_ids
        all_items.map(&:id).to_set
      end
    end

    class InvalidScope < ArgumentError; end

    def self.for_project(project, scope:, user: User.current, relation_types: DEFAULT_RELATION_TYPES)
      new(project, category: :project, scope: scope, user: user, relation_types: relation_types).select
    end

    def self.for_item(issue, scope:, user: User.current, relation_types: DEFAULT_RELATION_TYPES)
      new(issue, category: :item, scope: scope, user: user, relation_types: relation_types).select
    end

    def initialize(focus, category:, scope:, user: User.current, relation_types: DEFAULT_RELATION_TYPES)
      @focus = focus
      @category = category.to_sym
      @scope = scope.to_sym
      @user = user
      @relation_types = Array(relation_types).map(&:to_s).uniq
      reset_traversal_metrics
      validate_scope!
    end

    def select
      RenderCancellation.check!
      reset_traversal_metrics
      selection = PerformanceTrace.measure_with_sql(
        'selector.selection',
        category: @category, scope: @scope, focus_id: @focus.id
      ) { build_selection }
      PerformanceTrace.report('selector.traversal', traversal_metrics(selection))
      selection
    end

    private

    def build_selection
      projects = selected_projects
      candidate_ids = selected_item_ids(projects)
      @traversal_metrics[:candidate_item_ids].merge(candidate_ids)
      items = visible_items(candidate_ids)
      if @category == :item
        projects = Project.where(id: items.map(&:project_id).uniq)
                          .includes(:parent).order(:lft, :id).to_a
      end
      audience_ids = items.map(&:id).to_set
      relations, boundary_relations, relation_context = if @category == :item
                                                          select_item_relations(audience_ids, items)
                                                        else
                                                          select_relations(audience_ids)
                                                        end
      relation_context_ids = relation_context.map(&:id).to_set
      structural_ids = structural_ancestors(audience_ids, seed_items: items).map(&:id).to_set
      if (@category == :item && @scope == :node_and_descendants) ||
         (@category == :project && @scope == :project)
        structural_ids.merge(project_boundary_children(audience_ids))
      end
      structural_ids.merge(structural_ancestors(
        relation_context_ids, stop_ids: audience_ids,
        exclude_ids: audience_ids | relation_context_ids,
        seed_items: relation_context
      ).map(&:id))
      structural_context = visible_items(structural_ids.to_a).sort_by(&:id)

      selection = Selection.new(
        focus: @focus,
        category: @category,
        scope: @scope,
        projects: projects,
        audience_items: items,
        structural_context_items: structural_context,
        relations: relations,
        boundary_relations: boundary_relations,
        relation_context_items: relation_context
      )
      selection
    end

    # A bounded hierarchy view still displays the first child across a
    # project boundary. It is context, not audience: do not expand its
    # descendants unless the caller explicitly selected an across-project
    # scope.
    def project_boundary_children(parent_ids)
      return Set.new if parent_ids.empty?

      focus_project_id = @category == :project ? @focus.id : @focus.project_id
      children = Issue.visible(@user)
                      .where(parent_id: parent_ids.to_a)
                      .where.not(project_id: focus_project_id)
                      .includes(:tracker, :status, :priority, { project: :parent, parent: [:project, :tracker, :status, :priority] })
                      .to_a
      @traversal_metrics[:candidate_item_ids].merge(children.map(&:id))
      @traversal_metrics[:loaded_item_ids].merge(children.map(&:id))
      children.map(&:id).to_set
    end

    def reset_traversal_metrics
      @traversal_metrics = {
        candidate_item_ids: Set.new,
        loaded_item_ids: Set.new,
        relation_endpoint_ids: Set.new,
        structural_ancestor_ids: Set.new,
        examined_relation_rows: 0,
        examined_relation_ids: Set.new,
        causal_states_visited: Set.new,
        frontier_batches: 0
      }
    end

    def traversal_metrics(selection)
      unique_items_examined = @traversal_metrics[:candidate_item_ids] |
                              @traversal_metrics[:loaded_item_ids] |
                              @traversal_metrics[:relation_endpoint_ids] |
                              @traversal_metrics[:structural_ancestor_ids]
      {
        category: @category,
        scope: @scope,
        focus_id: @focus.id,
        candidate_items: @traversal_metrics[:candidate_item_ids].size,
        unique_items_examined: unique_items_examined.size,
        loaded_items: @traversal_metrics[:loaded_item_ids].size,
        relation_endpoint_items: @traversal_metrics[:relation_endpoint_ids].size,
        structural_ancestors_visited: @traversal_metrics[:structural_ancestor_ids].size,
        relation_rows_examined: @traversal_metrics[:examined_relation_rows],
        unique_relations_examined: @traversal_metrics[:examined_relation_ids].size,
        causal_states_visited: @traversal_metrics[:causal_states_visited].size,
        frontier_batches: @traversal_metrics[:frontier_batches],
        result_audience_items: selection.audience_items.size,
        result_structural_context_items: selection.structural_context_items.size,
        result_relation_context_items: selection.relation_context_items.size,
        result_unique_items: selection.all_items.size,
        result_internal_relations: selection.relations.size,
        result_boundary_relations: selection.boundary_relations.size
      }
    end

    def validate_scope!
      allowed = case @category
                when :project then PROJECT_SCOPES
                when :item then ITEM_SCOPES
                else []
                end
      return if allowed.include?(@scope)

      raise InvalidScope, "unsupported #{@category} view scope: #{@scope.inspect}"
    end

    def selected_projects
      return [] unless @category == :project

      projects = case @scope
                 when :project
                   [@focus]
                 when :project_and_ancestors
                   @focus.self_and_ancestors.to_a
                 when :project_and_descendants
                   @focus.self_and_descendants.to_a
                 when :project_ancestors_and_descendants
                   (@focus.self_and_ancestors.to_a + @focus.self_and_descendants.to_a)
                 end
      project_ids = projects.uniq(&:id).select { |project| project.visible?(@user) }.map(&:id)
      Project.where(id: project_ids).includes(:parent).order(:lft, :id).to_a
    end

    def selected_item_ids(projects)
      if @category == :project
        return Issue.where(project_id: projects.map(&:id)).pluck(:id).to_set
      end

      case @scope
      when :node
        Set[@focus.id]
      when :node_and_descendants
        same_project_subtree_ids
      when :project
        Issue.where(project_id: @focus.project_id).pluck(:id).to_set
      when :node_and_descendants_across_projects
        descendants_in_item_tree
      when :node_and_descendants_with_successors, :node_and_descendants_with_predecessors
        descendants_in_item_tree
      when :node_ancestors_and_descendants
        ancestors_in_item_tree | descendants_in_item_tree
      end
    end

    def descendants_in_item_tree
      selected = Set[@focus.id]
      pending = [@focus.id]

      until pending.empty?
        RenderCancellation.check!
        children = Issue.visible(@user).where(parent_id: pending).pluck(:id)
        @traversal_metrics[:candidate_item_ids].merge(children)
        fresh = children.reject { |issue_id| selected.include?(issue_id) }
        selected.merge(fresh)
        pending = fresh
      end

      selected
    end

    def ancestors_in_item_tree
      selected = Set.new
      pending = [@focus.parent_id].compact

      until pending.empty?
        RenderCancellation.check!
        parents = visible_items(pending)
        fresh = parents.reject { |issue| selected.include?(issue.id) }
        selected.merge(fresh.map(&:id))
        pending = fresh.filter_map(&:parent_id)
      end

      selected
    end

    # The plain node-and-descendants window stops at the first project
    # boundary. It must not re-enter the original project further down a
    # foreign project's subtree.
    def same_project_subtree_ids
      descendants_within_project(@focus.project_id)
    end

    def descendants_within_project(project_id)
      selected = Set[@focus.id]
      pending = [@focus.id]

      until pending.empty?
        RenderCancellation.check!
        children = Issue.visible(@user).where(parent_id: pending, project_id: project_id).pluck(:id)
        @traversal_metrics[:candidate_item_ids].merge(children)
        fresh = children.reject { |issue_id| selected.include?(issue_id) }
        selected.merge(fresh)
        pending = fresh
      end

      selected
    end

    def visible_items(ids)
      RenderCancellation.check!
      return [] if ids.empty?

      items = Issue.visible(@user).where(id: ids.to_a)
           .includes(
             :tracker, :status, :priority,
             { project: :parent, parent: [:project, :tracker, :status, :priority] }
           )
           .order(:id).to_a
      @traversal_metrics[:loaded_item_ids].merge(items.map(&:id))
      items
    end

    def structural_ancestors(seed_ids, stop_ids: seed_ids, exclude_ids: stop_ids, seed_items: nil)
      return [] if seed_ids.empty?

      found = {}
      visited = Set.new
      parent_ids = Array(seed_items || visible_items(seed_ids.to_a)).filter_map(&:parent_id).uniq

      until parent_ids.empty?
        RenderCancellation.check!
        ancestors = visible_items(parent_ids)
        fresh = ancestors.reject { |issue| visited.include?(issue.id) }
        break if fresh.empty?

        fresh.each do |issue|
          visited << issue.id
          @traversal_metrics[:structural_ancestor_ids] << issue.id
          found[issue.id] = issue unless exclude_ids.include?(issue.id)
        end
        parent_ids = fresh.reject { |issue| stop_ids.include?(issue.id) }.filter_map(&:parent_id).uniq
      end

      found.values.sort_by(&:id)
    end

    def select_relations(audience_ids)
      return [[], [], []] if audience_ids.empty? || @relation_types.empty?

      relation_scope = IssueRelation
        .where(relation_type: @relation_types)
        .where('issue_from_id IN (:ids) OR issue_to_id IN (:ids)', ids: audience_ids.to_a)
        .includes(
          issue_from: [
            :tracker, :status, :priority,
            { project: :parent, parent: [:project, :tracker, :status, :priority] }
          ],
          issue_to: [
            :tracker, :status, :priority,
            { project: :parent, parent: [:project, :tracker, :status, :priority] }
          ]
        )
        .order(:id)

      internal = []
      boundary = []
      context_by_id = {}

      scanned_relations = relation_scope.to_a
      record_examined_relations(scanned_relations)
      scanned_relations.each do |relation|
        from = relation.issue_from
        to = relation.issue_to
        next unless from&.visible?(@user) && to&.visible?(@user)

        from_in = audience_ids.include?(relation.issue_from_id)
        to_in = audience_ids.include?(relation.issue_to_id)
        if from_in && to_in
          internal << relation
        elsif from_in || to_in
          boundary << relation
          context_issue = from_in ? to : from
          context_by_id[context_issue.id] = context_issue
        end
      end

      [internal, boundary, context_by_id.values.sort_by(&:id)]
    end

    # Discover item-diagram dependencies from the selected seeds, rather than
    # loading the project's whole issue tree and asking ViewAudienceModel to
    # walk it afterwards. Each causal path retains its initial direction.
    def select_item_relations(audience_ids, audience_items)
      return [[], [], []] if audience_ids.empty? || @relation_types.empty?

      items_by_id = audience_items.index_by(&:id)
      focus_project_id = @focus.project_id
      focus_children = Issue.visible(@user).where(parent_id: @focus.id)
                            .includes(:project, :tracker).to_a
      @traversal_metrics[:candidate_item_ids].merge(focus_children.map(&:id))
      @traversal_metrics[:loaded_item_ids].merge(focus_children.map(&:id))
      container = focus_children.any?(&:cosmosys_diagram_visible?)
      all_edges = []

      case @scope
      when :node_and_descendants
        if container
          local_ids = audience_ids
          all_edges.concat(internal_relations(local_ids))
          all_edges.concat(causal_relation_walk(Set[@focus.id], items_by_id, directions: %i[upstream downstream], stop_at_project_boundary: true))
          all_edges.concat(causal_relation_walk(local_ids - Set[@focus.id], items_by_id, directions: [:downstream], stop_at_project_boundary: true))
          all_edges.concat(relates_relations(local_ids))
        else
          all_edges.concat(causal_relation_walk(audience_ids, items_by_id, directions: %i[upstream downstream], stop_at_project_boundary: true))
          all_edges.concat(relates_relations(audience_ids))
        end
      when :node_and_descendants_across_projects
        if container
          all_edges.concat(internal_relations(audience_ids))
          all_edges.concat(causal_relation_walk(Set[@focus.id], items_by_id, directions: %i[upstream downstream], stop_at_project_boundary: false))
          all_edges.concat(causal_relation_walk(audience_ids - Set[@focus.id], items_by_id, directions: [:downstream], stop_at_project_boundary: false))
          all_edges.concat(relates_relations(audience_ids))
        else
          all_edges.concat(causal_relation_walk(audience_ids, items_by_id, directions: %i[upstream downstream], stop_at_project_boundary: false))
          all_edges.concat(relates_relations(audience_ids))
        end
      when :node_and_descendants_with_successors
        all_edges.concat(internal_relations(audience_ids))
        all_edges.concat(causal_relation_walk(audience_ids, items_by_id, directions: [:downstream], stop_at_project_boundary: false))
      when :node_and_descendants_with_predecessors
        all_edges.concat(internal_relations(audience_ids))
        all_edges.concat(causal_relation_walk(audience_ids, items_by_id, directions: [:upstream], stop_at_project_boundary: false))
      else
        all_edges.concat(direct_relations(audience_ids))
      end

      all_edges = all_edges.uniq(&:id).sort_by(&:id)
      # Relation endpoint objects are already hydrated by the discovery
      # queries. Keep them for the RAM model and painter; only fetch any
      # missing direct endpoints (e.g. a relates edge) once.
      audience_id_set = audience_ids.to_set
      context_by_id = {}
      all_edges.each do |edge|
        from = edge.issue_from
        to = edge.issue_to
        @traversal_metrics[:relation_endpoint_ids] << from.id if from
        @traversal_metrics[:relation_endpoint_ids] << to.id if to
        next unless from&.visible?(@user) && to&.visible?(@user)

        from_in = audience_id_set.include?(from.id)
        to_in = audience_id_set.include?(to.id)
        context_by_id[to.id] = to unless to_in
        context_by_id[from.id] = from unless from_in
        items_by_id[from.id] ||= from
        items_by_id[to.id] ||= to
      end

      # Re-fetch relation endpoints through the common presentation preload
      # only when an association did not arrive with the needed attributes.
      context_items = context_by_id.values
      internal = all_edges.select { |edge| audience_id_set.include?(edge.issue_from_id) && audience_id_set.include?(edge.issue_to_id) }
      boundary = all_edges.reject { |edge| internal.include?(edge) }
      [internal, boundary, context_items.sort_by(&:id)]
    end

    def direct_relations(item_ids)
      relation_query('issue_from_id IN (:ids) OR issue_to_id IN (:ids)', item_ids.to_a)
    end

    def internal_relations(item_ids)
      return [] if item_ids.empty?

      relations = IssueRelation.where(relation_type: @relation_types, issue_from_id: item_ids.to_a, issue_to_id: item_ids.to_a)
                               .includes(relation_endpoints_includes).order(:id).to_a
      record_examined_relations(relations)
      relations
    end

    def relates_relations(item_ids)
      return [] unless @relation_types.include?('relates')

      relations = IssueRelation.where(relation_type: 'relates')
                               .where('issue_from_id IN (:ids) OR issue_to_id IN (:ids)', ids: item_ids.to_a)
                               .includes(relation_endpoints_includes).order(:id).to_a
      record_examined_relations(relations)
      relations
    end

    def causal_relation_walk(seed_ids, known_items, directions:, stop_at_project_boundary:)
      return [] if seed_ids.empty?

      selected = {}
      visited = Set.new
      frontiers = Array(directions).to_h do |direction|
        ids = seed_ids.to_a
        ids.each do |id|
          visited << [id, direction]
          @traversal_metrics[:causal_states_visited] << [id, direction]
        end
        [direction, ids]
      end
      focus_project_id = @focus.project_id

      until frontiers.values.all?(&:empty?)
        RenderCancellation.check!
        frontiers.each do |direction, frontier_ids|
          next if frontier_ids.empty?

          batch_ids = frontier_ids.shift(frontier_ids.length)
          @traversal_metrics[:frontier_batches] += 1
          edge_scope = IssueRelation.where(relation_type: @relation_types & %w[blocks precedes])
          edge_scope = if direction == :upstream
                         edge_scope.where(issue_to_id: batch_ids)
                       else
                         edge_scope.where(issue_from_id: batch_ids)
          end
          edges = edge_scope.includes(relation_endpoints_includes).order(:id).to_a
          record_examined_relations(edges)
          next_frontier = []
          edges.each do |edge|
            next unless edge.issue_from&.visible?(@user) && edge.issue_to&.visible?(@user)

            selected[edge.id] = edge
            neighbor = direction == :upstream ? edge.issue_from : edge.issue_to
            @traversal_metrics[:relation_endpoint_ids] << edge.issue_from.id if edge.issue_from
            @traversal_metrics[:relation_endpoint_ids] << edge.issue_to.id if edge.issue_to
            next unless neighbor&.visible?(@user)
            next if stop_at_project_boundary && neighbor.project_id != focus_project_id

            known_items[neighbor.id] ||= neighbor
            state = [neighbor.id, direction]
            next unless visited.add?(state)
            @traversal_metrics[:causal_states_visited] << state

            next_frontier << neighbor.id
          end
          frontier_ids.concat(next_frontier)
        end
      end

      selected.values
    end

    def relation_query(where_sql, ids)
      RenderCancellation.check!
      return [] if ids.empty?

      relations = IssueRelation.where(relation_type: @relation_types)
                               .where(where_sql, ids: ids)
                               .includes(relation_endpoints_includes).order(:id).to_a
      record_examined_relations(relations)
      relations
    end

    def record_examined_relations(relations)
      rows = Array(relations)
      @traversal_metrics[:examined_relation_rows] += rows.size
      @traversal_metrics[:examined_relation_ids].merge(rows.map(&:id))
      rows.each do |relation|
        @traversal_metrics[:relation_endpoint_ids] << relation.issue_from_id
        @traversal_metrics[:relation_endpoint_ids] << relation.issue_to_id
      end
    end

    def relation_endpoints_includes
      {
        issue_from: [:tracker, :status, :priority, { project: :parent, parent: [:project, :tracker, :status, :priority] }],
        issue_to: [:tracker, :status, :priority, { project: :parent, parent: [:project, :tracker, :status, :priority] }]
      }
    end
  end
end
