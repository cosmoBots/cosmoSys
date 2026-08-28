require 'digest'
require 'set'
require_relative 'document_reference_diagram_support'

module Cosmosys
  class DependencyDiagramService
    include Cosmosys::DiagramCacheSupport
    include Cosmosys::DocumentReferenceDiagramSupport

    KIND = 'dependency'.freeze
    FULL_KIND = 'dependency_full'.freeze
    SUPPORTED_RELATION_TYPES = %w[blocks precedes relates].freeze

    def self.fetch(issue, mode: :project_boundary, scope: :composite, include_document_references: true, relation_types: SUPPORTED_RELATION_TYPES)
      new(issue, mode: mode, scope: scope, include_document_references: include_document_references, relation_types: relation_types).fetch
    end

    def self.component_for(issue, mode: :project_boundary, scope: :self, relation_types: SUPPORTED_RELATION_TYPES)
      new(issue, mode: mode, scope: scope, include_document_references: false, relation_types: relation_types).send(:dependency_component)
    end

    def initialize(issue, mode: :project_boundary, scope: :composite, include_document_references: true, relation_types: SUPPORTED_RELATION_TYPES)
      @issue = issue
      @mode = mode
      @scope = %i[self subtree].include?(scope.to_s.to_sym) ? scope.to_s.to_sym : :composite
      @include_document_references = include_document_references
      @relation_types = Array(relation_types).map(&:to_s) & SUPPORTED_RELATION_TYPES
    end

    def fetch
      discovery = Cosmosys::PerformanceTrace.measure('diagram.discovery', issue_id: @issue.id, kind: diagram_kind) do
        { signature: dependency_signature, empty: !@issue.cosmosys_diagram_visible? || dependency_content_empty? }
      end
      fetch_cached_diagram(
        scope_attrs: { issue_id: @issue.id },
        kind: diagram_kind,
        empty: discovery[:empty],
        signature: discovery[:signature]
      ) { build_dot }
    end

    private

    def diagram_kind
      base_kind = @mode == :full ? FULL_KIND : KIND
      base_kind = "#{base_kind}_subtree" if @scope == :subtree
      @include_document_references ? base_kind : "#{base_kind}_without_document_refs"
    end

    def build_dot
      renderer.build_graph(title: 'cosmosys_dependency', rankdir: @issue.cosmosys_dependency_rankdir) do |lines|
        @scope == :composite ? append_composite_graph(lines) : append_component_graph(lines, dependency_component)
      end
    end

    def append_composite_graph(lines)
      own = own_component
      internal = remaining_subtree_component
      own_container_ids = own[:issues].filter_map(&:parent_id).to_set

      own[:issues].each do |issue|
        lines.concat(renderer.build_node(
          issue,
          boundary: own[:boundary_issue_ids].include?(issue.id),
          dependency_container: own_container_ids.include?(issue.id),
          namespace: 'context'
        ))
      end
      own[:relations].each { |relation| lines.concat(renderer.build_edge(relation, namespace: 'context')) }

      if internal[:relations].any?
        lines.concat(renderer.build_subtree_cluster(@issue, label: I18n.t(:label_cosmosys_subtree_dependency_diagram)) do |cluster_lines|
          internal_container_ids = internal[:issues].filter_map(&:parent_id).to_set
          internal[:issues].each do |issue|
            cluster_lines.concat(renderer.build_node(
              issue,
              boundary: false,
              dependency_container: internal_container_ids.include?(issue.id),
              namespace: 'subtree'
            ))
          end
          internal[:relations].each { |relation| cluster_lines.concat(renderer.build_edge(relation, namespace: 'subtree')) }
        end)
        lines.concat(renderer.build_subtree_zoom_edge(@issue))
      end

      append_document_references(lines, own_issue_ids: own[:issues].map(&:id).to_set)
    end

    def append_component_graph(lines, component)
      component_container_ids = component[:issues].filter_map(&:parent_id).to_set
      component[:issues].each do |issue|
        lines.concat(renderer.build_node(
          issue,
          boundary: component[:boundary_issue_ids].include?(issue.id),
          dependency_container: component_container_ids.include?(issue.id)
        ))
      end
      component[:relations].each { |relation| lines.concat(renderer.build_edge(relation)) }
      append_document_references(lines) if @include_document_references
    end

    def append_document_references(lines, own_issue_ids: nil)
      return unless @include_document_references

      emitted_entry_ids = Set.new
      visible_document_references.each do |catalog_ref|
        entry_id = catalog_ref.document_catalog_entry_id
        namespace = own_issue_ids ? (own_issue_ids.include?(catalog_ref.issue_id) ? 'context' : 'subtree') : nil
        lines.concat(renderer.build_document_reference(catalog_ref, emit_node: emitted_entry_ids.add?(entry_id), namespace: namespace))
      end
    end

    def dependency_component
      @dependency_component ||= if @issue.cosmosys_diagram_visible?
                                  if @scope == :subtree
                                    build_subtree_internal_component
                                  elsif @scope == :composite
                                    composite_component
                                  else
                                    @mode == :full ? build_full_component : build_project_boundary_component
                                  end
                                else
                                  { issues: [], relations: [], boundary_issue_ids: Set.new }
                                end
    end

    def own_component
      @own_component ||= @mode == :full ? build_full_component : build_project_boundary_component
    end

    def subtree_component
      @subtree_component ||= build_subtree_internal_component
    end

    def remaining_subtree_component
      @remaining_subtree_component ||= begin
        relations = subtree_component[:relations].reject { |relation| own_component[:relations].any? { |own_relation| own_relation.id == relation.id } }
        issue_ids = relations.flat_map { |relation| [relation.issue_from_id, relation.issue_to_id] }.to_set
        {
          issues: subtree_component[:issues].select { |issue| issue_ids.include?(issue.id) },
          relations: relations,
          boundary_issue_ids: Set.new
        }
      end
    end

    def composite_component
      internal = remaining_subtree_component
      {
        issues: (own_component[:issues] + internal[:issues]).uniq(&:id).sort_by(&:id),
        relations: (own_component[:relations] + internal[:relations]).uniq(&:id).sort_by(&:id),
        boundary_issue_ids: own_component[:boundary_issue_ids]
      }
    end

    def build_subtree_internal_component
      subtree_issues = @issue.self_and_descendants
                              .visible(User.current)
                              .includes(:project, :tracker)
                              .to_a
                              .select(&:cosmosys_diagram_visible?)
      subtree_by_id = subtree_issues.index_by(&:id)
      subtree_ids = subtree_by_id.keys
      relations = IssueRelation.includes(:issue_from, :issue_to)
                               .where(issue_from_id: subtree_ids, issue_to_id: subtree_ids)
                               .order(:id)
                               .select { |relation| supported_relation?(relation) }
      involved_ids = relations.flat_map { |relation| [relation.issue_from_id, relation.issue_to_id] }.to_set

      {
        issues: involved_ids.filter_map { |id| subtree_by_id[id] }.sort_by(&:id),
        relations: relations,
        boundary_issue_ids: Set.new
      }
    end

    def build_full_component
      build_causal_component(project_boundary: false)
    end

    def build_project_boundary_component
      build_causal_component(project_boundary: true)
    end

    def build_causal_component(project_boundary:)
      project_id = @issue.project_id
      visited_states = Set.new([[@issue.id, :seed]])
      boundary_ids = Set.new
      relation_ids = Set.new
      queue = [[@issue, :seed]]
      issues = []
      relations = []

      while queue.any?
        current, direction = queue.shift
        issues << current

        causal_relations_for(current, direction).each do |relation, neighbor, next_direction|
          next unless relation.issue_from && relation.issue_to

          unless relation_ids.include?(relation.id)
            relation_ids << relation.id
            relations << relation
          end

          if project_boundary && neighbor.project_id != project_id
            boundary_ids << neighbor.id
            issues << neighbor
            next
          end

          state = [neighbor.id, next_direction]
          next if visited_states.include?(state)

          visited_states << state
          queue << [neighbor, next_direction]
        end
      end

      {
        issues: issues.uniq(&:id).sort_by(&:id),
        relations: relations.uniq(&:id).sort_by(&:id),
        boundary_issue_ids: boundary_ids
      }
    end

    def causal_relations_for(issue, direction)
      visible_relations_for(issue).filter_map do |relation, neighbor|
        relation_type = relation.relation_type.to_s
        if relation_type == 'relates'
          next unless direction == :seed || direction == :related

          [relation, neighbor, :related]
        elsif relation.issue_from_id == issue.id
          next unless direction == :seed || direction == :downstream

          [relation, neighbor, :downstream]
        elsif relation.issue_to_id == issue.id
          next unless direction == :seed || direction == :upstream

          [relation, neighbor, :upstream]
        end
      end
    end

    def visible_relations_for(issue)
      pairs = []

      issue.relations_from.includes(:issue_to, :issue_from).each do |relation|
        next unless supported_relation?(relation)
        next unless relation.issue_to&.visible?(User.current)
        next unless relation.issue_to.cosmosys_diagram_visible?

        pairs << [relation, relation.issue_to]
      end

      issue.relations_to.includes(:issue_to, :issue_from).each do |relation|
        next unless supported_relation?(relation)
        next unless relation.issue_from&.visible?(User.current)
        next unless relation.issue_from.cosmosys_diagram_visible?

        pairs << [relation, relation.issue_from]
      end

      pairs
    end

    def connected_issues
      dependency_component[:issues]
    end

    def connected_relations
      dependency_component[:relations]
    end

    def dependency_content_empty?
      connected_relations.empty? && (!@include_document_references || visible_document_references.empty?)
    end

    def boundary_issue_ids
      dependency_component[:boundary_issue_ids]
    end

    def rendered_container_issue_ids
      @rendered_container_issue_ids ||= connected_issues.filter_map(&:parent_id).to_set
    end

    def supported_relation?(relation)
      @relation_types.include?(relation.relation_type.to_s) &&
        @issue.cosmosys_dependency_relation_visible?(relation.relation_type)
    end

    def dependency_signature
      payload = []
      payload << "mode:#{@mode}"
      payload << "document_refs:#{@include_document_references ? 1 : 0}"
      payload << "relations:#{@relation_types.sort.join(',')}"
      payload << "rankdir:#{@issue.cosmosys_dependency_rankdir}"
      payload << "scope:#{@scope}"
      if @scope == :composite
        payload << 'composition:v2'
        payload << "locale:#{I18n.locale}"
        payload << "context_issues:#{own_component[:issues].map(&:id).sort.join(',')}"
        payload << "context_relations:#{own_component[:relations].map(&:id).sort.join(',')}"
        payload << "subtree_issues:#{remaining_subtree_component[:issues].map(&:id).sort.join(',')}"
        payload << "subtree_relations:#{remaining_subtree_component[:relations].map(&:id).sort.join(',')}"
      end
      payload.concat(connected_issues.map do |issue|
        renderer.node_signature(
          issue,
          boundary: boundary_issue_ids.include?(issue.id),
          dependency_container: rendered_container_issue_ids.include?(issue.id)
        )
      end)
      payload.concat(connected_relations.filter_map { |relation| renderer.edge_signature(relation) })
      payload.concat(visible_document_references.map { |catalog_ref| renderer.document_reference_signature(catalog_ref) }) if @include_document_references
      Digest::SHA256.hexdigest(payload.join('|'))
    end

    def visible_document_references
      @visible_document_references ||= visible_document_references_for(connected_issues)
    end

    def renderer
      @renderer ||= Cosmosys::DependencyDiagramRenderer.new(current_issue: @issue)
    end
  end
end
