require 'digest'
require 'set'
require_relative 'document_reference_diagram_support'
require_relative 'dependency_diagram_service'

module Cosmosys
  class ProjectCombinedDiagramService
    include Cosmosys::DiagramCacheSupport
    include Cosmosys::DocumentReferenceDiagramSupport

    KIND = 'project_combined'.freeze
    FULL_KIND = 'project_combined_full'.freeze
    SUPPORTED_RELATION_TYPES = %w[blocks precedes relates].freeze

    def self.fetch(project, mode: :project_boundary, render_variant: nil, layout_mode: nil, include_document_references: true, relation_types: SUPPORTED_RELATION_TYPES)
      new(project, mode: mode, render_variant: render_variant, layout_mode: layout_mode, include_document_references: include_document_references, relation_types: relation_types).fetch
    end

    def initialize(project, mode: :project_boundary, render_variant: nil, layout_mode: nil, include_document_references: true, relation_types: SUPPORTED_RELATION_TYPES)
      @project = project
      @mode = mode
      @include_document_references = include_document_references
      @relation_types = Array(relation_types).map(&:to_s) & SUPPORTED_RELATION_TYPES
      @render_variant = Cosmosys::CombinedDiagramRenderer.valid_render_variant?(render_variant) ? render_variant.to_s : @project.cosmosys_combined_diagram_render_variant
      @layout_mode = Cosmosys::CombinedDiagramRenderer.valid_layout_mode?(layout_mode) ? layout_mode.to_s : @project.cosmosys_combined_diagram_layout_mode
    end

    def fetch
      discovery = Cosmosys::PerformanceTrace.measure('diagram.discovery', project_id: @project.id, kind: diagram_kind) do
        { signature: combined_signature, empty: all_rendered_issues.empty? }
      end
      fetch_cached_diagram(
        scope_attrs: { project_id: @project.id },
        kind: diagram_kind,
        empty: discovery[:empty],
        signature: discovery[:signature],
        render_variant: @render_variant,
        layout_mode: @layout_mode
      ) { build_dot }
    end

    private

    def diagram_kind
      @mode == :full ? FULL_KIND : KIND
    end

    def build_dot
      renderer.build_graph(title: 'cosmosys_project_combined') do |lines|
        project_roots.each do |issue|
          lines.concat(renderer.build_tree(build_project_subtree_entry(issue)))
        end
        dependency_boundary_issues.each do |issue|
          lines.concat(renderer.build_standalone_node(issue, boundary: true))
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
        .includes(:project, :tracker, :parent)
        .order(:csposition, :lft, :id)
        .to_a
        .select(&:cosmosys_diagram_visible?)
    end

    def visible_issue_ids
      @visible_issue_ids ||= visible_issues.map(&:id).to_set
    end

    def project_roots
      @project_roots ||= visible_issues.filter_map do |issue|
        if issue.parent_id.blank?
          issue
        elsif !visible_issue_ids.include?(issue.parent_id)
          issue.parent&.cosmosys_diagram_visible? ? issue.parent : issue
        end
      end.uniq(&:id)
    end

    def build_project_subtree_entry(issue)
      children = project_visible_children(issue).map do |child|
        if @mode == :full || child.project_id == @project.id
          build_project_subtree_entry(child)
        else
          { issue: child, boundary: true, children: [] }
        end
      end
      children = reorder_entries_for_variant(children)

      { issue: issue, boundary: issue.project_id != @project.id, children: children }
    end

    def project_visible_children(issue)
      issue.children.visible(User.current).includes(:project, :tracker).order(:csposition, :lft, :id).to_a.select do |child|
        next false unless child.cosmosys_diagram_visible?

        if @mode == :full
          true
        elsif issue.project_id == @project.id
          true
        else
          child.project_id == @project.id
        end
      end
    end

    def tree_issues
      @tree_issues ||= begin
        issues = []
        project_roots.each { |issue| collect_project_entry_issues(build_project_subtree_entry(issue), issues) }
        issues.uniq(&:id)
      end
    end

    def collect_project_entry_issues(entry, issues)
      issues << entry.fetch(:issue)
      Array(entry[:children]).each { |child| collect_project_entry_issues(child, issues) }
    end

    def tree_issue_ids
      @tree_issue_ids ||= tree_issues.map(&:id).to_set
    end

    def dependency_component
      @dependency_component ||= build_dependency_component
    end

    def build_dependency_component
      if @mode == :full
        components = tree_issues.map do |issue|
          Cosmosys::DependencyDiagramService.component_for(
            issue, mode: :full, scope: :self, relation_types: @relation_types
          )
        end
        return {
          relations: components.flat_map { |component| component[:relations] }.uniq(&:id).sort_by(&:id),
          boundary_issues: components.flat_map { |component| component[:issues] }.reject { |issue| tree_issue_ids.include?(issue.id) }.uniq(&:id).sort_by(&:id)
        }
      end

      relation_ids = Set.new
      relations = []
      boundary_issues = []

      tree_issues.each do |issue|
        visible_relations_for(issue).each do |relation, neighbor|
          next unless relation.issue_from && relation.issue_to
          next unless tree_issue_ids.include?(relation.issue_from_id) || tree_issue_ids.include?(relation.issue_to_id)

          unless relation_ids.include?(relation.id)
            relation_ids << relation.id
            relations << relation
          end

          next if tree_issue_ids.include?(neighbor.id)
          next if boundary_issues.any? { |candidate| candidate.id == neighbor.id }

          boundary_issues << neighbor
        end
      end

      {
        relations: relations.uniq(&:id).sort_by(&:id),
        boundary_issues: boundary_issues.uniq(&:id).sort_by(&:id)
      }
    end

    def visible_relations
      dependency_component[:relations]
    end

    def dependency_boundary_issues
      dependency_component[:boundary_issues]
    end

    def all_rendered_issues
      tree_issues + dependency_boundary_issues
    end

    def dependency_issue_ids
      @dependency_issue_ids ||= begin
        ids = Set.new
        visible_relations.each do |relation|
          ids << relation.issue_from_id if tree_issue_ids.include?(relation.issue_from_id)
          ids << relation.issue_to_id if tree_issue_ids.include?(relation.issue_to_id)
        end
        ids
      end
    end

    def cluster_title_issue_ids
      # All container issues (those with children in hierarchy) should be treated
      # as cluster titles, even if they have no internal dependency relations.
      @cluster_title_issue_ids ||= container_issue_ids.dup
    end

    def cluster_anchor_issue_ids
      @cluster_anchor_issue_ids ||= begin
        ids = Set.new
        container_issue_ids.each do |issue_id|
          next if cluster_title_issue_ids.include?(issue_id)
          next unless dependency_issue_ids.include?(issue_id)

          ids << issue_id
        end
        ids
      end
    end

    def visible_relations_for(issue)
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

    def combined_signature
      payload = []
      payload << "mode:#{@mode}"
      payload << "render_variant:#{@render_variant}"
      payload << "layout_mode:#{@layout_mode}"
      payload << "document_refs:#{@include_document_references ? 1 : 0}"
      payload << "relations:#{@relation_types.sort.join(',')}"
      project_roots.each { |issue| append_entry_signature(build_project_subtree_entry(issue), payload) }
      payload.concat(dependency_boundary_issues.map { |issue| renderer.node_signature(issue, boundary: true, container: false) })
      payload.concat(visible_relations.filter_map { |relation| renderer.edge_signature(relation) })
      payload.concat(visible_document_references.map { |catalog_ref| renderer.document_reference_signature(catalog_ref) }) if @include_document_references
      Digest::SHA256.hexdigest(payload.join('|'))
    end

    def visible_document_references
      @visible_document_references ||= visible_document_references_for(tree_issues)
    end

    def append_entry_signature(entry, payload)
      issue = entry.fetch(:issue)
      children = Array(entry[:children])
      boundary = entry[:boundary] == true
      if children.any?
        payload << renderer.cluster_signature(
          issue,
          boundary: boundary,
          show_container_node: cluster_title_issue_ids.include?(issue.id),
          show_anchor_node: cluster_anchor_issue_ids.include?(issue.id)
        )
        payload << renderer.node_signature(issue, boundary: boundary, container: true) if cluster_title_issue_ids.include?(issue.id)
        payload << renderer.node_signature(issue, boundary: boundary, container: :anchor) if cluster_anchor_issue_ids.include?(issue.id)
      else
        payload << renderer.node_signature(issue, boundary: boundary, container: false)
      end
      children.each { |child| append_entry_signature(child, payload) }
    end

    def container_issue_ids
      @container_issue_ids ||= begin
        ids = Set.new
        project_entry_roots.each { |entry| collect_container_issue_ids(entry, ids) }
        ids
      end
    end

    def collect_container_issue_ids(entry, ids)
      children = Array(entry[:children])
      ids << entry.fetch(:issue).id if children.any?
      children.each { |child| collect_container_issue_ids(child, ids) }
    end

    def ancestor_ids_by_issue
      @ancestor_ids_by_issue ||= begin
        mapping = {}
        project_entry_roots.each { |entry| collect_ancestor_ids(entry, mapping, Set.new) }
        mapping
      end
    end

    def collect_ancestor_ids(entry, mapping, ancestor_ids)
      issue = entry.fetch(:issue)
      mapping[issue.id] = ancestor_ids.dup
      child_ancestor_ids = ancestor_ids.dup << issue.id
      Array(entry[:children]).each { |child| collect_ancestor_ids(child, mapping, child_ancestor_ids) }
    end

    def descendant_relation?(ancestor_id:, descendant_id:)
      (ancestor_ids_by_issue[descendant_id] || Set.new).include?(ancestor_id)
    end

    def project_entry_roots
      @project_entry_roots ||= project_roots.map { |issue| build_project_subtree_entry(issue) }
    end

    def reorder_entries_for_variant(children)
      return children unless @render_variant == 'v2'
      return children if children.size < 2

      metrics = entry_reorder_metrics(children)
      return children if metrics.values.all? { |metric| metric[:external_count].zero? && metric[:sibling_count].zero? }

      ranked = children.sort_by do |entry|
        metric = metrics.fetch(entry.object_id)
        [-metric[:external_count], -metric[:sibling_count], metric[:original_index]]
      end
      slots = center_out_slot_indexes(children.size)
      arranged = Array.new(children.size)
      ranked.each_with_index { |entry, index| arranged[slots[index]] = entry }
      arranged
    end

    def entry_reorder_metrics(children)
      child_issue_ids = {}
      issue_to_child_index = {}
      children.each_with_index do |entry, index|
        ids = collect_entry_ids(entry)
        child_issue_ids[entry.object_id] = ids
        ids.each { |issue_id| issue_to_child_index[issue_id] = index }
      end

      children.each_with_index.each_with_object({}) do |(entry, index), metrics|
        external_partners = Set.new
        sibling_partners = Set.new
        child_ids = child_issue_ids.fetch(entry.object_id)
        child_ids.each do |issue_id|
          dependency_neighbor_ids_for(issue_id).each do |partner_id|
            next if child_ids.include?(partner_id)

            partner_index = issue_to_child_index[partner_id]
            if partner_index.present? && partner_index != index
              sibling_partners << partner_id
            elsif partner_index.nil?
              external_partners << partner_id
            end
          end
        end
        metrics[entry.object_id] = {
          original_index: index,
          external_count: external_partners.size,
          sibling_count: sibling_partners.size
        }
      end
    end

    def collect_entry_ids(entry, ids = Set.new)
      ids << entry.fetch(:issue).id
      Array(entry[:children]).each { |child| collect_entry_ids(child, ids) }
      ids
    end

    def center_out_slot_indexes(size)
      center = (size - 1) / 2.0
      (0...size).sort_by { |index| [(index - center).abs, index] }
    end

    def dependency_neighbor_ids_for(issue_id)
      @dependency_neighbor_ids_for ||= {}
      @dependency_neighbor_ids_for[issue_id] ||= begin
        issue = Issue.find_by(id: issue_id)
        issue ? visible_relations_for(issue).map { |_relation, neighbor| neighbor.id }.to_set : Set.new
      end
    end

    def renderer
      @renderer ||= Cosmosys::CombinedDiagramRenderer.new(
        cluster_title_issue_ids: cluster_title_issue_ids,
        cluster_anchor_issue_ids: cluster_anchor_issue_ids,
        layout_mode: @layout_mode
      )
    end
  end
end
