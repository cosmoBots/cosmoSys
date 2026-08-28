require 'digest'
require 'set'
require_relative 'document_reference_diagram_support'

module Cosmosys
  class ProjectDependencyDiagramService
    include Cosmosys::DiagramCacheSupport
    include Cosmosys::DocumentReferenceDiagramSupport

    KIND = 'project_dependency'.freeze
    FULL_KIND = 'project_dependency_full'.freeze
    SUPPORTED_RELATION_TYPES = %w[blocks precedes relates].freeze

    def self.fetch(project, mode: :project_boundary, include_document_references: true, relation_types: SUPPORTED_RELATION_TYPES)
      new(project, mode: mode, include_document_references: include_document_references, relation_types: relation_types).fetch
    end

    def initialize(project, mode: :project_boundary, include_document_references: true, relation_types: SUPPORTED_RELATION_TYPES)
      @project = project
      @mode = mode
      @include_document_references = include_document_references
      @relation_types = Array(relation_types).map(&:to_s) & SUPPORTED_RELATION_TYPES
    end

    def fetch
      discovery = Cosmosys::PerformanceTrace.measure('diagram.discovery', project_id: @project.id, kind: diagram_kind) do
        { signature: dependency_signature, empty: rendered_issues.empty? }
      end
      fetch_cached_diagram(
        scope_attrs: { project_id: @project.id },
        kind: diagram_kind,
        empty: discovery[:empty],
        signature: discovery[:signature]
      ) { build_dot }
    end

    private

    def diagram_kind
      @mode == :full ? FULL_KIND : KIND
    end

    def build_dot
      rankdir = rendered_issues.first&.cosmosys_dependency_rankdir || 'LR'
      renderer.build_graph(title: 'cosmosys_project_dependency', rankdir: rankdir) do |lines|
        rendered_issues.each do |issue|
          lines.concat(renderer.build_node(
            issue,
            boundary: boundary_issue_ids.include?(issue.id),
            dependency_container: rendered_container_issue_ids.include?(issue.id)
          ))
        end
        visible_relations.each do |relation|
          lines.concat(renderer.build_edge(relation))
        end
        if @include_document_references
          emitted_entry_ids = Set.new
          visible_document_references.each do |catalog_ref|
            entry_id = catalog_ref.document_catalog_entry_id
            lines.concat(renderer.build_document_reference(catalog_ref, emit_node: emitted_entry_ids.add?(entry_id)))
          end
        end
      end
    end

    def visible_issues
      @visible_issues ||= Issue.visible(User.current)
        .where(project_id: @project.id)
        .includes(:project, :tracker)
        .order(:csposition, :lft, :id)
        .to_a
        .select(&:cosmosys_diagram_visible?)
    end

    def visible_issue_ids
      @visible_issue_ids ||= visible_issues.map(&:id).to_set
    end

    def rendered_issues
      @rendered_issues ||= (component[:issues] + (@include_document_references ? document_reference_issues : [])).uniq(&:id).sort_by(&:id)
    end

    def visible_relations
      @visible_relations ||= component[:relations]
    end

    def boundary_issue_ids
      component[:boundary_issue_ids]
    end

    def component
      @component ||= (@mode == :full ? build_full_component : build_project_boundary_component)
    end

    def build_full_component
      relations = []
      visible_issues.each do |issue|
        issue.relations_from.includes(:issue_to, :issue_from).each do |relation|
          next unless supported_relation?(issue, relation)
          next unless visible_issue_ids.include?(relation.issue_to_id)

          relations << relation
        end
      end

      {
        issues: issues_for_relations(relations),
        relations: relations.uniq(&:id).sort_by(&:id),
        boundary_issue_ids: Set.new
      }
    end

    def build_project_boundary_component
      boundary_issues = []
      relations = []

      visible_issues.each do |issue|
        visible_relation_pairs_for(issue).each do |relation, neighbor|
          next unless relation.issue_from && relation.issue_to

          if visible_issue_ids.include?(neighbor.id)
            relations << relation
          else
            boundary_issues << neighbor
            relations << relation
          end
        end
      end

      boundary_issues = boundary_issues.uniq(&:id).sort_by(&:id)

      {
        issues: issues_for_relations(relations),
        relations: relations.uniq(&:id).sort_by(&:id),
        boundary_issue_ids: boundary_issues.map(&:id).to_set
      }
    end

    def visible_relation_pairs_for(issue)
      pairs = []

      issue.relations_from.includes(:issue_to, :issue_from).each do |relation|
        next unless supported_relation?(issue, relation)
        next unless relation.issue_to&.visible?(User.current)
        next unless relation.issue_to.cosmosys_diagram_visible?

        pairs << [relation, relation.issue_to]
      end

      issue.relations_to.includes(:issue_to, :issue_from).each do |relation|
        next unless supported_relation?(issue, relation)
        next unless relation.issue_from&.visible?(User.current)
        next unless relation.issue_from.cosmosys_diagram_visible?

        pairs << [relation, relation.issue_from]
      end

      pairs
    end

    def supported_relation?(issue, relation)
      @relation_types.include?(relation.relation_type.to_s) &&
        issue.cosmosys_dependency_relation_visible?(relation.relation_type)
    end

    def issues_for_relations(relations)
      issue_ids = relations.flat_map { |relation| [relation.issue_from_id, relation.issue_to_id] }.to_set
      (visible_issues + Array(boundary_issues_for(relations))).select { |issue| issue_ids.include?(issue.id) }.uniq(&:id)
    end

    def boundary_issues_for(relations)
      relations.flat_map { |relation| [relation.issue_from, relation.issue_to] }.compact.reject do |issue|
        visible_issue_ids.include?(issue.id)
      end
    end

    def rendered_container_issue_ids
      @rendered_container_issue_ids ||= rendered_issues.filter_map(&:parent_id).to_set
    end

    def dependency_signature
      payload = []
      payload << "mode:#{@mode}"
      payload << "document_refs:#{@include_document_references ? 1 : 0}"
      payload << "relations:#{@relation_types.sort.join(',')}"
      payload << "rankdir:#{rendered_issues.first&.cosmosys_dependency_rankdir || 'LR'}"
      payload.concat(rendered_issues.map do |issue|
        renderer.node_signature(
          issue,
          boundary: boundary_issue_ids.include?(issue.id),
          dependency_container: rendered_container_issue_ids.include?(issue.id)
        )
      end)
      payload.concat(visible_relations.filter_map { |relation| renderer.edge_signature(relation) })
      payload.concat(visible_document_references.map { |catalog_ref| renderer.document_reference_signature(catalog_ref) }) if @include_document_references
      Digest::SHA256.hexdigest(payload.join('|'))
    end

    def visible_document_references
      @visible_document_references ||= visible_document_references_for(visible_issues)
    end

    def document_reference_issues
      reference_issue_ids = visible_document_references.map(&:issue_id).to_set
      visible_issues.select { |issue| reference_issue_ids.include?(issue.id) }
    end

    def renderer
      @renderer ||= Cosmosys::DependencyDiagramRenderer.new
    end
  end
end
