require 'digest'
require 'set'
require_relative 'document_reference_diagram_support'
require_relative 'dependency_diagram_service'

module Cosmosys
  class CombinedDiagramService
    include Cosmosys::DiagramCacheSupport
    include Cosmosys::DocumentReferenceDiagramSupport

    KIND = 'combined'.freeze
    FULL_KIND = 'combined_full'.freeze
    SUPPORTED_RELATION_TYPES = %w[blocks precedes relates].freeze

    def self.fetch(issue, mode: :project_boundary, render_variant: nil, layout_mode: nil, include_document_references: true, relation_types: SUPPORTED_RELATION_TYPES)
      new(issue, mode: mode, render_variant: render_variant, layout_mode: layout_mode, include_document_references: include_document_references, relation_types: relation_types).fetch
    end

    def initialize(issue, mode: :project_boundary, render_variant: nil, layout_mode: nil, include_document_references: true, relation_types: SUPPORTED_RELATION_TYPES)
      @issue = issue
      @mode = mode
      @include_document_references = include_document_references
      @relation_types = Array(relation_types).map(&:to_s) & SUPPORTED_RELATION_TYPES
      @render_variant = Cosmosys::CombinedDiagramRenderer.valid_render_variant?(render_variant) ? render_variant.to_s : @issue.project.cosmosys_combined_diagram_render_variant
      @layout_mode = Cosmosys::CombinedDiagramRenderer.valid_layout_mode?(layout_mode) ? layout_mode.to_s : @issue.project.cosmosys_combined_diagram_layout_mode
    end

    def fetch
      discovery = Cosmosys::PerformanceTrace.measure('diagram.discovery', issue_id: @issue.id, kind: diagram_kind) do
        { signature: combined_signature, empty: !@issue.cosmosys_diagram_visible? || all_rendered_issues.empty? }
      end
      fetch_cached_diagram(
        scope_attrs: { issue_id: @issue.id },
        kind: diagram_kind,
        empty: discovery[:empty],
        signature: discovery[:signature],
        render_variant: @render_variant,
        layout_mode: @layout_mode
      ) { build_dot }
    end

    private

    def diagram_kind
      base_kind = @mode == :full ? FULL_KIND : KIND
      @include_document_references ? base_kind : "#{base_kind}_without_document_refs"
    end

    def build_dot
      renderer.build_graph(title: 'cosmosys_combined') do |lines|
        root_entries.each { |entry| lines.concat(renderer.build_tree(entry)) }
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

    def hierarchy_issue_ids
      @hierarchy_issue_ids ||= begin
        ids = Set.new
        root_entries.each { |entry| collect_entry_issue_ids(entry, ids) }
        ids
      end
    end

    def collect_entry_issue_ids(entry, ids)
      ids << entry.fetch(:issue).id
      Array(entry[:children]).each { |child| collect_entry_issue_ids(child, ids) }
    end

    def dependency_boundary_issues
      @dependency_boundary_issues ||= dependency_component[:issues].reject { |issue| hierarchy_issue_ids.include?(issue.id) }
    end

    def dependency_boundary_issue_ids
      @dependency_boundary_issue_ids ||= dependency_boundary_issues.map(&:id).to_set
    end

    def all_rendered_issues
      @all_rendered_issues ||= tree_issues + dependency_boundary_issues
    end

    def tree_issues
      @tree_issues ||= begin
        issues = []
        root_entries.each { |entry| collect_entry_issues(entry, issues) }
        issues.uniq(&:id)
      end
    end

    def collect_entry_issues(entry, issues)
      issues << entry.fetch(:issue)
      Array(entry[:children]).each { |child| collect_entry_issues(child, issues) }
    end

    def dependency_issue_ids
      @dependency_issue_ids ||= begin
        ids = Set.new
        visible_relations.each do |relation|
          ids << relation.issue_from_id if hierarchy_issue_ids.include?(relation.issue_from_id)
          ids << relation.issue_to_id if hierarchy_issue_ids.include?(relation.issue_to_id)
        end
        ids
      end
    end

    def cluster_title_issue_ids
      # All container issues (those with children in hierarchy) should be treated as cluster titles
      # regardless of whether they have internal dependency relations.
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

    def dependency_component
      @dependency_component ||= begin
        own = Cosmosys::DependencyDiagramService.component_for(@issue, mode: @mode, scope: :self, relation_types: @relation_types)
        if @issue.children.visible(User.current).exists?
          internal = Cosmosys::DependencyDiagramService.component_for(@issue, mode: @mode, scope: :subtree, relation_types: @relation_types)
          {
            issues: (own[:issues] + internal[:issues]).uniq(&:id).sort_by(&:id),
            relations: (own[:relations] + internal[:relations]).uniq(&:id).sort_by(&:id),
            boundary_issue_ids: own[:boundary_issue_ids] | internal[:boundary_issue_ids]
          }
        else
          own
        end
      end
    end

    def visible_relations
      dependency_component[:relations]
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

    def supported_relation?(relation)
      @relation_types.include?(relation.relation_type.to_s) &&
        @issue.cosmosys_dependency_relation_visible?(relation.relation_type)
    end

    def combined_signature
      payload = []
      payload << "mode:#{@mode}"
      payload << "document_refs:#{@include_document_references ? 1 : 0}"
      payload << "relations:#{@relation_types.sort.join(',')}"
      payload << "render_variant:#{@render_variant}"
      payload << "layout_mode:#{@layout_mode}"
      root_entries.each { |entry| append_entry_signature(entry, payload) }
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

    def root_entries
      @root_entries ||= selected_root_entries(contextualized_issue_ids)
    end

    def contextualized_issue_ids
      @contextualized_issue_ids ||= begin
        selected = primary_hierarchy_issues.index_by(&:id)
        dependency_component[:issues].each { |issue| selected[issue.id] = issue }

        selected.values.each do |issue|
          issue.ancestors.visible(User.current).includes(:project, :tracker).each do |ancestor|
            next unless ancestor.cosmosys_diagram_visible?
            next unless primary_hierarchy_issue_ids.include?(ancestor.id) || ancestor.project_id == issue.project_id

            selected[ancestor.id] = ancestor
          end
        end
        selected.keys.to_set
      end
    end

    def primary_hierarchy_issues
      @primary_hierarchy_issues ||= if @mode == :full
                                      issues = []
                                      collect_entry_issues(full_root_entry, issues)
                                      issues.uniq(&:id)
                                    else
                                      scoped_base_subtree_issues
                                    end
    end

    def primary_hierarchy_issue_ids
      @primary_hierarchy_issue_ids ||= primary_hierarchy_issues.map(&:id).to_set
    end

    def selected_root_entries(included_ids)
      included_issues = Issue.visible(User.current)
                             .where(id: included_ids)
                             .includes(:project, :tracker)
                             .order(:csposition, :lft, :id)
                             .to_a
                             .select(&:cosmosys_diagram_visible?)
      included_by_id = included_issues.index_by(&:id)
      included_issues
        .select { |issue| !included_by_id.key?(issue.parent_issue_id) }
        .map { |issue| build_selected_subtree_entry(issue, included_by_id) }
    end

    def full_root_entry
      chain = @issue.self_and_ancestors.to_a.select(&:cosmosys_diagram_visible?)
      entry = build_full_subtree_entry(@issue)
      chain[0..-2].reverse_each do |ancestor|
        entry = { issue: ancestor, boundary: ancestor.project_id != @issue.project_id, children: [entry] }
      end
      entry
    end

    def build_full_subtree_entry(issue)
      {
        issue: issue,
        boundary: issue.project_id != @issue.project_id,
        children: full_visible_children(issue).map { |child| build_full_subtree_entry(child) }
      }
    end

    def full_visible_children(issue)
      issue.children.visible(User.current).includes(:project, :tracker).order(:csposition, :lft, :id).to_a.select(&:cosmosys_diagram_visible?)
    end

    def scoped_root_entries
      selected_root_entries(scoped_included_issue_ids)
    end

    def build_selected_subtree_entry(issue, included_by_id)
      children = issue.children.visible(User.current)
                      .where(id: included_by_id.keys)
                      .includes(:project, :tracker)
                      .order(:csposition, :lft, :id)
                      .to_a
                      .select(&:cosmosys_diagram_visible?)
                      .map { |child| build_selected_subtree_entry(child, included_by_id) }
      children = reorder_entries_for_variant(children)
      { issue: issue, boundary: issue.project_id != @issue.project_id, children: children }
    end

    def scoped_included_issue_ids
      @scoped_included_issue_ids ||= begin
        base_issues = scoped_base_subtree_issues
        selected = base_issues.index_by(&:id)

        dependency_component[:issues].each { |issue| selected[issue.id] = issue }

        selected.values.each do |issue|
          issue.ancestors.visible(User.current).includes(:project, :tracker).each do |ancestor|
            next unless ancestor.cosmosys_diagram_visible?
            next unless ancestor.project_id == issue.project_id || issue.id == @issue.id

            selected[ancestor.id] = ancestor
          end
        end
        selected.keys.to_set
      end
    end

    def scoped_base_subtree_issues
      issues = []
      collect_scoped_base_issues(@issue, issues)
      issues
    end

    def collect_scoped_base_issues(issue, issues)
      return unless issue.cosmosys_diagram_visible?

      issues << issue
      scoped_visible_children(issue).each do |child|
        if child.project_id == @issue.project_id
          collect_scoped_base_issues(child, issues)
        else
          issues << child
        end
      end
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

    def scoped_visible_children(issue)
      issue.children.visible(User.current).includes(:project, :tracker).order(:csposition, :lft, :id).to_a.select(&:cosmosys_diagram_visible?)
    end

    def container_issue_ids
      @container_issue_ids ||= begin
        ids = Set.new
        root_entries.each { |entry| collect_container_issue_ids(entry, ids) }
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
        root_entries.each { |entry| collect_ancestor_ids(entry, mapping, Set.new) }
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

    def renderer
      @renderer ||= Cosmosys::CombinedDiagramRenderer.new(
        current_issue: @issue,
        cluster_title_issue_ids: cluster_title_issue_ids,
        cluster_anchor_issue_ids: cluster_anchor_issue_ids,
        layout_mode: @layout_mode
      )
    end
  end
end
