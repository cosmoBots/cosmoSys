require 'set'

module Cosmosys
  # Immutable, ActiveRecord-free projection of the content selected for a view.
  # It can be built from a live selector result or from a portable snapshot
  # fixture, so diagram code and tests can share one data contract.
  class ViewAudienceModel
    Project = Struct.new(:id, :identifier, :name, :cscode, :parent_identifier, keyword_init: true)
    Item = Struct.new(
      :id, :source_id, :csid, :csidnum, :subject, :description, :tracker,
      :project_id, :project_identifier, :parent_id, :position, :tree_left,
      :status, :priority, :due_date, :done_ratio, :profile, :url, :presentation,
      keyword_init: true
    )
    Relation = Struct.new(
      :id, :source_id, :from_item_id, :to_item_id, :relation_type, :delay,
      :restricted, :boundary, keyword_init: true
    )

    attr_reader :focus_id, :category, :scope, :projects, :audience_items,
                :structural_context_items, :relation_context_items, :relations,
                :boundary_relations

    def self.from_selection(selection)
      new(
        focus_id: focus_identity(selection.focus),
        category: selection.category,
        scope: selection.scope,
        projects: project_records(selection),
        audience_items: item_records(selection.audience_items, selection),
        structural_context_items: item_records(selection.structural_context_items, selection),
        relation_context_items: item_records(selection.relation_context_items, selection),
        relations: relation_records(selection.relations, boundary: false),
        boundary_relations: relation_records(selection.boundary_relations, boundary: true)
      )
    end

    # Builds the same value model from the portable, generic Feature projection
    # embedded in the Osiris diagram-selection reference. This path needs no
    # Redmine boot or database connection.
    def self.from_feature_snapshot(snapshot)
      projects = Array(snapshot.fetch('projects')).map do |project|
        Project.new(
          identifier: project.fetch('identifier').to_s,
          name: project['name'].to_s,
          cscode: project['cscode'].to_s,
          parent_identifier: project['parent_project']&.to_s
        )
      end
      item_rows = Array(snapshot.fetch('projects')).flat_map do |project|
        Array(project.fetch('items')).map do |item|
          Item.new(
            id: item.fetch('csid').to_s,
            csid: item.fetch('csid').to_s,
            subject: item.fetch('subject').to_s,
            tracker: item.fetch('tracker').to_s,
            project_identifier: project.fetch('identifier').to_s,
            parent_id: item['parent_csid']&.to_s,
            presentation: {}
          )
        end
      end
      relations = Array(snapshot.fetch('relations')).each_with_index.map do |relation, index|
        from_id = relation.fetch('from').to_s
        to_id = relation.fetch('to').to_s
        Relation.new(
          id: relation['id']&.to_s || [from_id, relation.fetch('type'), to_id, relation.fetch('delay', 0), index].join(':'),
          from_item_id: from_id,
          to_item_id: to_id,
          relation_type: relation.fetch('type').to_s,
          delay: relation.fetch('delay', 0).to_i,
          restricted: relation.fetch('restricted', false) == true,
          boundary: false
        )
      end

      new(
        category: :fixture,
        scope: :all,
        projects: projects,
        audience_items: item_rows,
        relations: relations,
        boundary_relations: []
      )
    end

    # Rehydrates a canonical node/adjacency selection captured from a diagram
    # into the same paint-model objects produced for live selector results.
    def self.from_feature_selection(snapshot:, selection:, focus_id:, category:, scope:)
      source = from_feature_snapshot(snapshot)
      selected_ids = Array(selection.fetch('nodes')).map(&:to_s).to_set
      boundary_ids = Array(selection['boundary_nodes']).map(&:to_s).to_set
      items_by_id = source.all_items.to_h { |item| [item.id, item] }
      missing = selected_ids - items_by_id.keys.to_set
      raise ArgumentError, "diagram selection references missing items: #{missing.to_a.sort.join(', ')}" unless missing.empty?

      selected_items = selected_ids.map do |item_id|
        item = items_by_id.fetch(item_id).dup
        item.parent_id = nil unless selected_ids.include?(item.parent_id)
        item
      end
      audience_items = selected_items.reject { |item| boundary_ids.include?(item.id) }
      context_items = selected_items.select { |item| boundary_ids.include?(item.id) }
      adjacency_rows = Array(selection['adjacencies']).filter_map do |row|
        case row.length
        when 3
          next unless row[0].to_s == 'contains'

          [row[1].to_s, row[2].to_s, 'contains', 0]
        when 4
          [row[0].to_s, row[1].to_s, row[2].to_s, row[3].to_i]
        end
      end
      internal_edges = []
      boundary_edges = []
      adjacency_rows.each_with_index do |(from_id, to_id, type, delay), index|
        next unless selected_ids.include?(from_id) && selected_ids.include?(to_id)

        edge_boundary = boundary_ids.include?(from_id) || boundary_ids.include?(to_id)
        edge = Relation.new(
          id: "reference:#{index}:#{type}:#{from_id}:#{to_id}",
          from_item_id: from_id,
          to_item_id: to_id,
          relation_type: type,
          delay: delay,
          restricted: false,
          boundary: edge_boundary
        )
        (edge_boundary ? boundary_edges : internal_edges) << edge
      end
      visible_project_ids = selected_items.map(&:project_identifier).to_set
      visible_projects = source.projects.select { |project| visible_project_ids.include?(project.identifier) }

      new(
        focus_id: focus_id,
        category: category,
        scope: scope,
        projects: visible_projects,
        audience_items: audience_items,
        relation_context_items: context_items,
        relations: internal_edges,
        boundary_relations: boundary_edges
      )
    end

    # Applies the project-centered audience scopes to a portable feature model.
    # This mirrors the selector contract without needing Rails or ActiveRecord,
    # which makes saved snapshots usable by the diagram laboratory.
    def for_project(identifier, scope: :project, relation_types: %w[blocks precedes relates])
      identifier = identifier.to_s
      project_by_identifier = projects.to_h { |project| [project.identifier, project] }
      focus = project_by_identifier[identifier]
      raise ArgumentError, "unknown project #{identifier.inspect}" unless focus

      selected_project_ids = case scope.to_sym
                             when :project
                               Set[identifier]
                               when :project_and_descendants
                               projects.each_with_object(Set.new) do |project, selected|
                                 selected << project.identifier if project.identifier == identifier || self.class.send(:descendant_project?, project, identifier, project_by_identifier)
                               end
                             when :project_ancestors_and_descendants
                               ancestors = self.class.send(:project_ancestors, identifier, project_by_identifier)
                               projects.each_with_object(ancestors.to_set) do |project, selected|
                                 selected << project.identifier if project.identifier == identifier || self.class.send(:descendant_project?, project, identifier, project_by_identifier)
                               end
                             else
                               raise ArgumentError, "unsupported project scope: #{scope.inspect}"
                             end

      # Ancestor projects are not wholesale audience seeds. Seed only the
      # focal project's branch; ancestor items enter through directional
      # relation paths, so discovering a predecessor cannot fan out through
      # its successors into sibling project branches.
      relation_seed_project_ids = if scope.to_sym == :project_ancestors_and_descendants
                                    projects.each_with_object(Set.new) do |project, selected|
                                      selected << project.identifier if project.identifier == identifier ||
                                        self.class.send(:descendant_project?, project, identifier, project_by_identifier)
                                    end
                                  else
                                    selected_project_ids
                                  end

      selected_project_records = projects.select { |project| selected_project_ids.include?(project.identifier) }
      audience = all_items.select { |item| relation_seed_project_ids.include?(item.project_identifier) }
      audience_ids = audience.map(&:id).to_set
      by_id = all_items.to_h { |item| [item.id, item] }
      structural = self.class.send(:structural_ancestor_ids, audience_ids, items_by_id: by_id, stop_ids: audience_ids)
      allowed_types = Array(relation_types).map(&:to_s).to_set
      matching_edges = if scope.to_sym == :project_ancestors_and_descendants
                         path_edges = self.class.send(
                           :directional_relation_closure,
                           audience_ids,
                           relations.select { |edge| allowed_types.include?(edge.relation_type) },
                           directions: %i[upstream downstream]
                         )
                         undirected_edges = relations.select do |edge|
                           allowed_types.include?(edge.relation_type) && edge.relation_type == 'relates' &&
                             (audience_ids.include?(edge.from_item_id) || audience_ids.include?(edge.to_item_id))
                         end
                         (path_edges + undirected_edges).uniq(&:id)
                       else
                         relations.select { |edge| allowed_types.include?(edge.relation_type) &&
                           (audience_ids.include?(edge.from_item_id) || audience_ids.include?(edge.to_item_id)) }
                       end
      internal_edges = matching_edges.select do |edge|
        audience_ids.include?(edge.from_item_id) && audience_ids.include?(edge.to_item_id)
      end
      boundary_edges = matching_edges.reject { |edge| internal_edges.include?(edge) }.map do |edge|
        edge.dup.tap { |copy| copy.boundary = true }
      end
      boundary_ids = boundary_edges.flat_map do |edge|
        [edge.from_item_id, edge.to_item_id].reject { |item_id| audience_ids.include?(item_id) }
      end.to_set
      relation_context = all_items.select { |item| boundary_ids.include?(item.id) }
      # A direct relation endpoint outside the audience may be nested in a
      # different project. Include only its parent chain so the painter can
      # place it correctly; do not expand that endpoint's siblings/subtree.
      structural.merge(self.class.send(
        :structural_ancestor_ids, boundary_ids, items_by_id: by_id,
        stop_ids: audience_ids, exclude_ids: audience_ids | boundary_ids
      ))
      structural_items = all_items.select { |item| structural.include?(item.id) }
      visible_projects = (selected_project_records + (structural_items + relation_context).filter_map do |item|
        project_by_identifier[item.project_identifier]
      end).uniq(&:identifier)

      self.class.new(
        focus_id: identifier,
        category: :project,
        scope: scope,
        projects: visible_projects,
        audience_items: audience,
        structural_context_items: structural_items,
        relation_context_items: relation_context,
        relations: internal_edges,
        boundary_relations: boundary_edges
      )
    end

    # Applies item-centered scopes to the portable graph. This deliberately
    # mirrors the ActiveRecord selector so the diagram lab can exercise the
    # same audience rules without booting Redmine.
    def for_item(identifier, scope: :node, relation_types: %w[blocks precedes relates])
      identifier = identifier.to_s
      item_by_id = all_items.to_h { |item| [item.id, item] }
      focus = item_by_id[identifier]
      raise ArgumentError, "unknown item #{identifier.inspect}" unless focus

      scope = scope.to_sym
      container_focus = all_items.any? { |item| item.parent_id == identifier }
      audience_ids = case scope
                     when :node
                       Set[identifier]
                     when :node_and_descendants
                       self.class.send(:item_descendants, identifier, item_by_id, cross_projects: container_focus)
                     when :project
                       all_items.select { |item| item.project_identifier == focus.project_identifier }.map(&:id).to_set
                     when :node_and_descendants_across_projects
                       self.class.send(:item_descendants, identifier, item_by_id, cross_projects: true)
                     when :node_and_descendants_with_successors,
                          :node_and_descendants_with_predecessors
                       self.class.send(:item_descendants, identifier, item_by_id, cross_projects: true)
                     when :node_ancestors_and_descendants
                       self.class.send(:item_ancestors, identifier, item_by_id) |
                         self.class.send(:item_descendants, identifier, item_by_id, cross_projects: true)
                     else
                       raise ArgumentError, "unsupported item scope: #{scope.inspect}"
                     end

      audience = all_items.select { |item| audience_ids.include?(item.id) }
      allowed_relation_types = Array(relation_types).map(&:to_s).to_set
      eligible_relations = relations.select { |edge| allowed_relation_types.include?(edge.relation_type) }
      matching_edges = case scope
                       when :node_and_descendants_with_successors
                         self.class.send(:directional_relation_closure, audience_ids, eligible_relations, directions: [:downstream])
                       when :node_and_descendants_with_predecessors
                         self.class.send(:directional_relation_closure, audience_ids, eligible_relations, directions: [:upstream])
                       when :node_and_descendants_across_projects
                         if container_focus
                           self.class.send(:container_relation_closure, identifier, audience_ids, eligible_relations)
                         else
                           self.class.send(:directional_relation_closure, audience_ids, eligible_relations, directions: [:downstream])
                         end
                       when :node_and_descendants
                         if container_focus
                           self.class.send(:container_relation_closure, identifier, audience_ids, eligible_relations)
                         else
                           self.class.send(:local_item_relation_closure, identifier, audience_ids, eligible_relations, item_by_id)
                         end
                       else
                         eligible_relations.select do |edge|
                           audience_ids.include?(edge.from_item_id) || audience_ids.include?(edge.to_item_id)
                         end
                       end
      internal_edges = matching_edges.select do |edge|
        audience_ids.include?(edge.from_item_id) && audience_ids.include?(edge.to_item_id)
      end
      boundary_edges = matching_edges.reject { |edge| internal_edges.include?(edge) }.map do |edge|
        edge.dup.tap { |copy| copy.boundary = true }
      end
      boundary_ids = boundary_edges.flat_map do |edge|
        [edge.from_item_id, edge.to_item_id].reject { |item_id| audience_ids.include?(item_id) }
      end.to_set

      structural_ids = self.class.send(
        :structural_ancestor_ids, audience_ids, items_by_id: item_by_id, stop_ids: audience_ids
      )
      structural_ids.merge(self.class.send(
        :structural_ancestor_ids, boundary_ids, items_by_id: item_by_id,
        stop_ids: audience_ids, exclude_ids: audience_ids | boundary_ids
      ))
      structural_items = all_items.select { |item| structural_ids.include?(item.id) }
      relation_context = all_items.select { |item| boundary_ids.include?(item.id) }
      visible_project_ids = (audience + structural_items + relation_context).map(&:project_identifier).to_set
      visible_projects = projects.select { |project| visible_project_ids.include?(project.identifier) }

      self.class.new(
        focus_id: identifier,
        category: :item,
        scope: scope,
        projects: visible_projects,
        audience_items: audience,
        structural_context_items: structural_items,
        relation_context_items: relation_context,
        relations: internal_edges,
        boundary_relations: boundary_edges
      )
    end

    def initialize(focus_id: nil, category:, scope:, projects:, audience_items:, structural_context_items: [], relation_context_items: [], relations: [], boundary_relations: [])
      @focus_id = focus_id&.to_s
      @category = category.to_sym
      @scope = scope.to_sym
      @projects = self.class.send(:freeze_records, projects)
      @audience_items = self.class.send(:freeze_records, audience_items)
      @structural_context_items = self.class.send(:freeze_records, structural_context_items)
      @relation_context_items = self.class.send(:freeze_records, relation_context_items)
      @relations = self.class.send(:freeze_records, relations)
      @boundary_relations = self.class.send(:freeze_records, boundary_relations)
      @items_by_id = all_items.each_with_object({}) { |item, index| index[item.id] = item }.freeze
      validate_endpoints!(@items_by_id.keys.to_set)
      freeze
    end

    def all_items
      (audience_items + structural_context_items + relation_context_items).uniq(&:id)
    end

    def item_ids
      all_items.map(&:id).to_set
    end

    def all_relations
      relations + boundary_relations
    end

    def item(id)
      @items_by_id[id.to_s]
    end

    def to_h
      {
        'focus_id' => focus_id,
        'category' => category.to_s,
        'scope' => scope.to_s,
        'projects' => projects.map(&:to_h),
        'audience_items' => audience_items.map(&:to_h),
        'structural_context_items' => structural_context_items.map(&:to_h),
        'relation_context_items' => relation_context_items.map(&:to_h),
        'relations' => relations.map(&:to_h),
        'boundary_relations' => boundary_relations.map(&:to_h)
      }
    end

    def validate_endpoints!(known_item_ids = item_ids)
      (relations + boundary_relations).each do |relation|
        missing = [relation.from_item_id, relation.to_item_id] - known_item_ids.to_a
        next if missing.empty?

        raise ArgumentError, "relation #{relation.id.inspect} references missing items: #{missing.join(', ')}"
      end
      true
    end

    class << self
      private

      def structural_ancestor_ids(seed_ids, items_by_id:, stop_ids:, exclude_ids: stop_ids)
        found = Set.new
        visited = Set.new
        pending = seed_ids.filter_map { |item_id| items_by_id[item_id]&.parent_id }.uniq

        until pending.empty?
          ancestors = pending.filter_map { |item_id| items_by_id[item_id] }
          fresh = ancestors.reject { |item| visited.include?(item.id) }
          break if fresh.empty?

          fresh.each do |item|
            visited << item.id
            found << item.id unless exclude_ids.include?(item.id)
          end
          pending = fresh.reject { |item| stop_ids.include?(item.id) }.filter_map(&:parent_id).uniq
        end

        found
      end

      def item_descendants(identifier, items_by_id, cross_projects:)
        focus = items_by_id.fetch(identifier)
        children_by_parent = items_by_id.values.group_by(&:parent_id)
        selected = Set.new
        pending = [identifier]

        until pending.empty?
          current_id = pending.shift
          current = items_by_id[current_id]
          next unless current && selected.add?(current_id)

          Array(children_by_parent[current_id]).each do |child|
            next if !cross_projects && child.project_identifier != focus.project_identifier

            pending << child.id
          end
        end

        selected
      end

      def item_ancestors(identifier, items_by_id)
        ancestors = Set.new
        current = items_by_id[identifier]
        while current&.parent_id && ancestors.add?(current.parent_id)
          current = items_by_id[current.parent_id]
        end
        ancestors
      end

      # Follow causal paths from every item in the structural audience. Each
      # path keeps its initial direction: an outgoing path never turns around
      # to follow predecessors, and vice versa. This captures impact/precursor
      # context without letting discovered context nodes fan out into unrelated
      # branches.
      def directional_relation_closure(seed_ids, relations, directions: %i[upstream downstream])
        outgoing = relations.group_by(&:from_item_id)
        incoming = relations.group_by(&:to_item_id)
        selected = {}
        queue = seed_ids.flat_map { |item_id| directions.map { |direction| [item_id, direction] } }
        visited = queue.to_set

        until queue.empty?
          item_id, direction = queue.shift
          edges = direction == :upstream ? incoming[item_id] : outgoing[item_id]
          Array(edges).each do |edge|
            next unless %w[blocks precedes].include?(edge.relation_type)

            selected[edge.id] = edge
            neighbor_id = direction == :upstream ? edge.from_item_id : edge.to_item_id
            state = [neighbor_id, direction]
            next unless visited.add?(state)

            queue << state
          end
        end

        selected.values.sort_by(&:id)
      end

      # A container is a boundary for hierarchy scope, not a reason to pull
      # in its own parent's sibling branches. Its contents are always included
      # across project interfaces. Relations on the container may lead either
      # way; relations emitted by its contents continue downstream only.
      def container_relation_closure(container_id, audience_ids, relations)
        internal_edges = relations.select do |edge|
          audience_ids.include?(edge.from_item_id) && audience_ids.include?(edge.to_item_id)
        end
        descendant_ids = audience_ids - Set[container_id]
        focus_edges = directional_relation_closure(Set[container_id], relations, directions: %i[upstream downstream])
        descendant_edges = directional_relation_closure(descendant_ids, relations, directions: [:downstream])
        relates_edges = relations.select do |edge|
          edge.relation_type == 'relates' &&
            (audience_ids.include?(edge.from_item_id) || audience_ids.include?(edge.to_item_id))
        end
        (internal_edges + focus_edges + descendant_edges + relates_edges).uniq(&:id).sort_by(&:id)
      end

      # For a leaf-like focus, follow incoming and outgoing dependency paths
      # independently. Continue within the focus project, include the first
      # item reached across a project boundary, and stop that path there. The
      # caller adds only the hierarchy needed to place those boundary items.
      def local_item_relation_closure(focus_id, audience_ids, relations, items_by_id)
        focus_project = items_by_id[focus_id]&.project_identifier
        path_edges = directional_relation_closure_to_project_boundary(
          audience_ids, relations, items_by_id: items_by_id,
          focus_project: focus_project, directions: %i[upstream downstream]
        )
        relates_edges = relations.select do |edge|
          edge.relation_type == 'relates' &&
            (audience_ids.include?(edge.from_item_id) || audience_ids.include?(edge.to_item_id))
        end
        (path_edges + relates_edges).uniq(&:id).sort_by(&:id)
      end

      # Like directional_relation_closure, each path keeps the direction in
      # which it left its seed. A cross-project edge is visible, but its far
      # endpoint is terminal here; otherwise a local view could fan out into
      # sibling projects from a boundary item.
      def directional_relation_closure_to_project_boundary(seed_ids, relations, items_by_id:, focus_project:, directions:)
        outgoing = relations.group_by(&:from_item_id)
        incoming = relations.group_by(&:to_item_id)
        selected = {}
        queue = seed_ids.flat_map { |item_id| directions.map { |direction| [item_id, direction] } }
        visited = queue.to_set

        until queue.empty?
          item_id, direction = queue.shift
          edges = direction == :upstream ? incoming[item_id] : outgoing[item_id]
          Array(edges).each do |edge|
            next unless %w[blocks precedes].include?(edge.relation_type)

            selected[edge.id] = edge
            neighbor_id = direction == :upstream ? edge.from_item_id : edge.to_item_id
            next unless items_by_id[neighbor_id]&.project_identifier == focus_project

            state = [neighbor_id, direction]
            next unless visited.add?(state)

            queue << state
          end
        end

        selected.values.sort_by(&:id)
      end

      def descendant_project?(project, ancestor_identifier, project_by_identifier)
        parent_identifier = project.parent_identifier
        while parent_identifier
          return true if parent_identifier == ancestor_identifier

          parent_identifier = project_by_identifier[parent_identifier]&.parent_identifier
        end
        false
      end

      def project_ancestors(identifier, project_by_identifier)
        ancestors = Set.new
        parent_identifier = project_by_identifier[identifier]&.parent_identifier
        while parent_identifier && ancestors.add?(parent_identifier)
          parent_identifier = project_by_identifier[parent_identifier]&.parent_identifier
        end
        ancestors
      end

      def focus_identity(focus)
        if focus.respond_to?(:csid)
          focus.csid.presence || "item:#{focus.id}"
        else
          focus.identifier.to_s
        end
      end

      def project_records(selection)
        item_projects = (selection.audience_items + selection.structural_context_items + selection.relation_context_items).map(&:project)
        projects_by_id = (Array(selection.projects) + item_projects).compact.uniq(&:id).to_h { |project| [project.id, project] }
        projects_by_id.values.map do |project|
          Project.new(
            id: project.id,
            identifier: project.identifier.to_s,
            name: project.name.to_s,
            cscode: project.cscode.to_s,
            parent_identifier: project.parent&.identifier&.to_s
          )
        end
      end

      def item_records(issues, selection)
        all_issues = selection.audience_items + selection.structural_context_items + selection.relation_context_items
        included_by_source_id = all_issues.to_h { |issue| [issue.id, issue] }
        Array(issues).map do |issue|
          item_id = issue.csid.presence || "item:#{issue.id}"
          parent = included_by_source_id[issue.parent_id]
          Item.new(
            id: item_id.to_s,
            source_id: issue.id,
            csid: issue.csid&.to_s,
            csidnum: issue.csidnum,
            subject: issue.subject.to_s,
            description: issue.description.to_s,
            tracker: issue.tracker&.name.to_s,
            project_id: issue.project_id,
            project_identifier: issue.project&.identifier.to_s,
            parent_id: parent && (parent.csid.presence || "item:#{parent.id}").to_s,
            position: issue.csposition,
            tree_left: issue.lft,
            status: issue.status&.name.to_s,
            priority: issue.priority&.name.to_s,
            due_date: issue.due_date&.iso8601,
            done_ratio: issue.done_ratio.to_i,
            profile: issue.cosmosys_item_kind_key.to_s,
            url: Rails.application.routes.url_helpers.issue_path(issue),
            presentation: issue_presentation(issue)
          )
        end
      end

      def relation_records(relations, boundary:)
        Array(relations).map do |relation|
          Relation.new(
            id: "relation:#{relation.id}",
            source_id: relation.id,
            from_item_id: relation.issue_from.csid.presence || "item:#{relation.issue_from_id}",
            to_item_id: relation.issue_to.csid.presence || "item:#{relation.issue_to_id}",
            relation_type: relation.relation_type.to_s,
            delay: relation.delay.to_i,
            restricted: relation.respond_to?(:csys_restricted) ? relation.csys_restricted == true : false,
            boundary: boundary
          )
        end
      end

      def issue_presentation(issue)
        %w[hierarchy combined dependency].to_h do |kind|
          labels = [false, true].to_h do |boundary|
            [boundary ? 'boundary' : 'normal', {
              'node_label' => issue.cosmosys_diagram_node_label(kind, boundary: boundary, dependency_container: false),
              'container_node_label' => issue.cosmosys_diagram_node_label(kind, boundary: boundary, dependency_container: true),
              'cluster_label' => issue.cosmosys_hierarchy_cluster_label(boundary: boundary),
              'container_label' => issue.cosmosys_hierarchy_container_label(boundary: boundary),
              'font_name' => issue.cosmosys_diagram_font_name(kind, boundary: boundary),
              'container_font_name' => issue.cosmosys_diagram_font_name(kind, boundary: boundary)
            }]
          end
          [kind, {
            'labels' => labels,
            'shape' => issue.cosmosys_diagram_shape(kind).to_s,
            'fill_color' => issue.cosmosys_diagram_fill_color(kind).to_s,
            'border_color' => issue.cosmosys_diagram_border_color(kind).to_s,
            'font_color' => issue.cosmosys_diagram_font_color(kind).to_s,
            'node_margin' => issue.cosmosys_diagram_node_margin(kind).to_s,
            'sibling_rank' => issue.cosmosys_diagram_sibling_rank(kind),
            'penwidth' => issue.cosmosys_diagram_penwidth(kind),
            'cluster_color' => issue.cosmosys_hierarchy_cluster_color.to_s,
            'cluster_fill_color' => issue.cosmosys_hierarchy_cluster_fill_color&.to_s,
            'cluster_penwidth' => issue.cosmosys_hierarchy_cluster_penwidth
          }]
        end
      end

      def freeze_records(records)
        Array(records).each do |record|
          freeze_value(record)
        end.freeze
      end

      def freeze_value(value)
        case value
        when Hash
          value.each { |key, entry| freeze_value(key); freeze_value(entry) }
          value.freeze
        when Array
          value.each { |entry| freeze_value(entry) }
          value.freeze
        when Struct
          value.each_pair { |_key, entry| freeze_value(entry) }
          value.freeze
        else
          value.freeze unless value.frozen? || value.nil? || value.is_a?(Numeric) || value == true || value == false || value.is_a?(Symbol)
          value
        end
      end
    end
  end
end
