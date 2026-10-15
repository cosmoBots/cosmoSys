require 'set'

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
      project_and_descendants
      project_ancestors_and_descendants
    ].freeze

    ITEM_SCOPES = %i[
      node
      node_and_descendants
      project
      node_and_descendants_across_projects
      node_ancestors_and_descendants
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
      :diagram_model,
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
      validate_scope!
    end

    def select
      projects = selected_projects
      items = visible_items(selected_item_ids(projects))
      projects = Project.where(id: items.map(&:project_id).uniq).order(:lft, :id).to_a if @category == :item
      audience_ids = items.map(&:id).to_set
      relations, boundary_relations, relation_context = select_relations(audience_ids)
      relation_context_ids = relation_context.map(&:id).to_set
      structural_ids = structural_ancestors(audience_ids).map(&:id).to_set
      structural_ids.merge(structural_ancestors(
        relation_context_ids, stop_ids: audience_ids,
        exclude_ids: audience_ids | relation_context_ids
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
      selection.diagram_model = ViewAudienceModel.from_selection(selection)
      selection
    end

    private

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
                 when :project_and_descendants
                   @focus.self_and_descendants.to_a
                 when :project_ancestors_and_descendants
                   (@focus.self_and_ancestors.to_a + @focus.self_and_descendants.to_a)
                 end
      projects.uniq(&:id).select { |project| project.visible?(@user) }
              .sort_by { |project| [project.lft.to_i, project.id.to_i] }
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
      when :node_ancestors_and_descendants
        ancestors_in_item_tree | descendants_in_item_tree
      end
    end

    def descendants_in_item_tree
      selected = Set[@focus.id]
      pending = [@focus.id]

      until pending.empty?
        children = Issue.visible(@user).where(parent_id: pending).pluck(:id)
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
      visible_by_id = visible_items(Issue.where(project_id: @focus.project_id).pluck(:id)).index_by(&:id)
      children_by_parent = visible_by_id.values.group_by(&:parent_id)
      selected = Set.new
      pending = [@focus.id]

      until pending.empty?
        issue_id = pending.shift
        issue = visible_by_id[issue_id]
        next unless issue
        next unless issue.project_id == @focus.project_id
        next unless selected.add?(issue_id)

        Array(children_by_parent[issue_id]).each { |child| pending << child.id }
      end

      selected
    end

    def visible_items(ids)
      return [] if ids.empty?

      Issue.visible(@user).where(id: ids.to_a).includes(:project, :parent).order(:id).to_a
    end

    def structural_ancestors(seed_ids, stop_ids: seed_ids, exclude_ids: stop_ids)
      return [] if seed_ids.empty?

      found = {}
      visited = Set.new
      parent_ids = visible_items(seed_ids.to_a).filter_map(&:parent_id).uniq

      until parent_ids.empty?
        ancestors = visible_items(parent_ids)
        fresh = ancestors.reject { |issue| visited.include?(issue.id) }
        break if fresh.empty?

        fresh.each do |issue|
          visited << issue.id
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
        .includes(:issue_from, :issue_to)
        .order(:id)

      internal = []
      boundary = []
      context_by_id = {}

      relation_scope.each do |relation|
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
  end
end
