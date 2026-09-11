require 'open3'

module Cosmosys
  class CombinedDiagramRenderer
    CURRENT_ISSUE_HIGHLIGHT = '#2F6FDE'.freeze
    DEFAULT_LAYOUT_MODE = 'dot'.freeze
    VALID_LAYOUT_MODES = %w[dot fdp].freeze
    DEFAULT_RENDER_VARIANT = 'v1'.freeze
    VALID_RENDER_VARIANTS = %w[v1 v2].freeze

    def self.valid_layout_mode?(mode)
      VALID_LAYOUT_MODES.include?(mode.to_s)
    end

    def self.valid_render_variant?(variant)
      VALID_RENDER_VARIANTS.include?(variant.to_s)
    end

    def initialize(current_issue: nil, cluster_title_issue_ids: Set.new, cluster_anchor_issue_ids: Set.new, layout_mode: DEFAULT_LAYOUT_MODE)
      @current_issue = current_issue
      @cluster_title_issue_ids = cluster_title_issue_ids
      @cluster_anchor_issue_ids = cluster_anchor_issue_ids
      @ancestor_ids_by_issue = {}
      @layout_mode = self.class.valid_layout_mode?(layout_mode) ? layout_mode.to_s : DEFAULT_LAYOUT_MODE
    end

    def build_graph(title:)
      lines = []
      lines << %(digraph #{title} {)
      lines << %(  graph [bgcolor="transparent", margin=0, pad=0.5, rankdir=TB,#{layout_attr} nodesep=0.5, ranksep=0.3, compound=true, pack=1, overlap=false, mclimit=10];)
      lines << '  node [shape=record, style="filled", fontname="times", fontsize=10, margin="0.03,0.03", width=0, height=0, penwidth=0.5];'
      lines << '  subgraph "cluster_diagram_root" {'
      lines << '    label="";'
      lines << '    color="#d9d9d9";'
      lines << '    pencolor="#d9d9d9";'
      lines << '    penwidth="0.4";'
      lines << '    margin="1";'
      yield lines
      lines << '  }'
      lines << '}'
      lines.join("\n")
    end

    def build_tree(entry, ancestor_ids: Set.new)
      issue = entry.fetch(:issue)
      @ancestor_ids_by_issue[issue.id] ||= ancestor_ids.dup
      boundary = entry[:boundary] == true
      children = Array(entry[:children])
      child_ancestor_ids = ancestor_ids.dup << issue.id
      nested_lines = children.flat_map { |child| build_tree(child, ancestor_ids: child_ancestor_ids) }

      build_issue_box(issue, nested_lines: nested_lines, boundary: boundary)
    end

    def build_standalone_node(issue, boundary: false)
      build_issue_node(issue, boundary: boundary, container: false)
    end

    def build_edge(relation)
      attrs = edge_attrs(relation)
      return [] if attrs.blank?

      [%(#{attrs.fetch(:from_node_id)} -> #{attrs.fetch(:to_node_id)} [#{format_attrs(attrs.except(:from, :to, :from_node_id, :to_node_id))}];)]
    end

    def build_document_reference(catalog_ref, emit_node: true)
      lines = []
      lines << %(#{document_node_id_for(catalog_ref)} [#{format_attrs(document_node_attrs(catalog_ref))}];) if emit_node
      endpoint = document_reference_endpoint(catalog_ref.issue)
      edge_attrs = document_edge_attrs(catalog_ref)
      edge_attrs[:ltail] = cluster_id_for(catalog_ref.issue) if endpoint[:use_cluster_boundary]
      lines << %(#{endpoint[:node_id]} -> #{document_node_id_for(catalog_ref)} [#{format_attrs(edge_attrs)}];)
      lines
    end

    def document_reference_signature(catalog_ref)
      entry = catalog_ref.document_catalog_entry
      document = catalog_ref.document
      [
        'document_ref', catalog_ref.id, catalog_ref.issue_id, entry.id, entry.family,
        entry.position, catalog_ref.catalog_label, document.id, document.title,
        document.updated_on&.utc&.to_i, catalog_ref.sense, catalog_ref.location
      ].join(':')
    end

    def node_signature(issue, boundary: false, container: false)
      attrs = node_attrs(issue, boundary: boundary, container: container)
      [
        issue.id,
        boundary ? 1 : 0,
        container.to_s,
        attrs[:label],
        attrs[:shape],
        attrs[:fillcolor],
        attrs[:color],
        attrs[:fontcolor],
        attrs[:fontname],
        attrs[:penwidth]
      ].join(':')
    end

    def cluster_signature(issue, boundary: false, show_container_node: false, show_anchor_node: false)
      attrs = cluster_attrs(issue, boundary: boundary, show_container_node: show_container_node)
      [
        issue.id,
        boundary ? 1 : 0,
        show_container_node ? 1 : 0,
        show_anchor_node ? 1 : 0,
        attrs[:label],
        attrs[:color],
        attrs[:pencolor],
        attrs[:fontname],
        attrs[:penwidth]
      ].join(':')
    end

    def edge_signature(relation)
      attrs = edge_attrs(relation)
      return nil if attrs.blank?

      [
        relation.id,
        relation.relation_type,
        attrs.fetch(:from).id,
        attrs.fetch(:to).id,
        attrs[:color],
        attrs[:dir]
      ].join(':')
    end

    def render_svg(dot_body)
      stdout, stderr, status = Open3.capture3('dot', '-Tsvg', stdin_data: dot_body)
      raise "Graphviz dot failed: #{stderr.presence || 'unknown error'}" unless status.success?

      stdout.sub(/\A.*?<svg/m, '<svg')
    end

    private

    def document_node_attrs(catalog_ref)
      {
        label: catalog_ref.catalog_label,
        shape: 'note',
        style: 'filled',
        fillcolor: '#fff8c5',
        color: '#8a7f45',
        fontcolor: '#333333',
        fontname: 'times',
        URL: Rails.application.routes.url_helpers.document_path(catalog_ref.document),
        target: '_top',
        tooltip: catalog_ref.document.title,
        fontsize: 10,
        margin: '0.05,0.04',
        width: 0,
        height: 0,
        penwidth: 0.6
      }
    end

    def document_edge_attrs(catalog_ref)
      tooltip = [catalog_ref.sense.presence, catalog_ref.location.presence].compact.join(' — ')
      tooltip = catalog_ref.document.title if tooltip.blank?
      { style: 'dashed', dir: 'none', arrowhead: 'none', color: '#777777', penwidth: 0.7, tooltip: tooltip }
    end

    def document_reference_endpoint(issue)
      if cluster_title_issue?(issue)
        { node_id: gateway_node_id_for(issue), use_cluster_boundary: true }
      elsif cluster_anchor_issue?(issue)
        { node_id: gateway_node_id_for(issue), use_cluster_boundary: true }
      else
        { node_id: node_id_for(issue, container: false), use_cluster_boundary: false }
      end
    end

    def document_node_id_for(catalog_ref)
      "document_catalog_entry_#{catalog_ref.document_catalog_entry_id}"
    end

    def build_issue_box(issue, nested_lines:, boundary:)
      return build_issue_node(issue, boundary: boundary, container: false) if nested_lines.blank?

      show_container_node = @cluster_title_issue_ids.include?(issue.id)
      show_gateway_node = @cluster_title_issue_ids.include?(issue.id) || @cluster_anchor_issue_ids.include?(issue.id)
      attrs = cluster_attrs(issue, boundary: boundary, show_container_node: show_container_node)
      lines = []
      lines << %(subgraph "#{cluster_id_for(issue)}" {)
      lines << %(  label="#{escape(attrs[:label])}";)
      lines << %(  fontname="#{escape(attrs[:fontname])}";)
      lines << %(  fontsize="#{attrs[:fontsize]}";)
      lines << %(  color="#{escape(attrs[:color])}";)
      lines << %(  pencolor="#{escape(attrs[:pencolor])}";)
      lines << %(  penwidth="#{attrs[:penwidth]}";)
      lines << %(  margin="#{escape(attrs[:margin])}";)
      lines << %(  style="#{escape(attrs[:style])}";)
      lines << %(  URL="#{escape(attrs[:URL])}";)
      lines << %(  tooltip="#{escape(attrs[:tooltip])}";)
      lines << '  labeljust="l";'
      lines << '  labelloc="t";'
      if show_gateway_node
        # Add invisible gateway node at cluster center for external relations
        lines << %(  #{gateway_node_id_for(issue)} [shape="point", style="invis", width="0", height="0"];)
      end
      if show_container_node
        lines.concat(indent(build_issue_node(issue, boundary: boundary, container: true), 2))
      end
      if @cluster_anchor_issue_ids.include?(issue.id) && !@cluster_title_issue_ids.include?(issue.id)
        lines.concat(indent(build_issue_node(issue, boundary: boundary, container: :anchor), 2))
      end
      lines.concat(indent(nested_lines, 2))
      lines << '}'
      lines
    end

    def build_issue_node(issue, boundary:, container:)
      attrs = node_attrs(issue, boundary: boundary, container: container)
      [%(#{node_id_for(issue, container: container)} [#{format_attrs(attrs)}];)]
    end

    def node_attrs(issue, boundary:, container:)
      attrs = {
        label: node_label(issue, boundary: boundary, container: container),
        fillcolor: issue.cosmosys_diagram_fill_color('combined'),
        color: node_color(issue, container: container),
        fontcolor: issue.cosmosys_diagram_font_color('combined'),
        fontname: node_font_name(issue, boundary: boundary, container: container),
        shape: node_shape(issue: issue, container: container),
        URL: issue_url(issue),
        target: '_top',
        tooltip: issue.description.to_s,
        fontsize: 10,
        margin: node_margin(container: container),
        width: node_width(container: container),
        height: node_height(container: container),
        penwidth: node_penwidth(issue, container: container)
      }

      if @current_issue && issue.id == @current_issue.id && !container
        attrs[:penwidth] = issue.cosmosys_diagram_penwidth('combined', selected: true)
        attrs[:color] = issue.cosmosys_diagram_valid? ? CURRENT_ISSUE_HIGHLIGHT : 'red'
      end

      attrs
    end

    def cluster_attrs(issue, boundary:, show_container_node:)
      attrs = {
        label: show_container_node ? '' : issue.cosmosys_hierarchy_cluster_label(boundary: boundary),
        fontname: issue.cosmosys_hierarchy_cluster_font_name(boundary: boundary),
        fontsize: 10,
        color: issue.cosmosys_hierarchy_cluster_color,
        pencolor: issue.cosmosys_hierarchy_cluster_color,
        penwidth: issue.cosmosys_hierarchy_cluster_penwidth,
        margin: '2',
        style: 'solid',
        URL: issue_url(issue),
        tooltip: issue.description.to_s
      }

      if @current_issue && issue.id == @current_issue.id
        highlight = issue.cosmosys_diagram_valid? ? CURRENT_ISSUE_HIGHLIGHT : 'red'
        attrs[:color] = highlight
        attrs[:pencolor] = highlight
        attrs[:penwidth] = issue.cosmosys_hierarchy_cluster_penwidth(selected: true)
      end

      attrs
    end

    def node_label(issue, boundary:, container:)
      return '' if container == :anchor

      if container
        issue.cosmosys_hierarchy_container_label(boundary: boundary)
      else
        issue.cosmosys_diagram_node_label('combined', boundary: boundary)
      end
    end

    def node_font_name(issue, boundary:, container:)
      return 'times' if container == :anchor
      return 'times italic' if container

      issue.cosmosys_diagram_font_name('combined', boundary: boundary)
    end

    def node_shape(issue: nil, container:)
      return 'point' if container == :anchor
      container ? 'box' : issue.cosmosys_diagram_shape('combined')
    end

    def node_color(issue, container:)
      return 'transparent' if container == :anchor
      return 'transparent' if container

      issue.cosmosys_diagram_border_color('combined')
    end

    def node_penwidth(issue, container:)
      return 0 if container == :anchor
      return 0 if container

      issue.cosmosys_diagram_penwidth('combined')
    end

    def node_margin(container:)
      container ? '0.02,0.02' : '0.03,0.03'
    end

    def node_width(container:)
      container == :anchor ? 0.01 : 0
    end

    def node_height(container:)
      container == :anchor ? 0.01 : 0
    end

    def edge_attrs(relation)
      return nil unless relation.issue_from && relation.issue_to

      relation_type = relation.relation_type.to_s
      color = relation.issue_from.cosmosys_dependency_relation_color(relation_type)
      base = {
        color: color,
        penwidth: 0.8,
        arrowsize: 0.55,
        tooltip: relation_type,
        fontname: 'times',
        fontsize: 9
      }

      case relation_type
      when 'relates'
        from_issue = relation.issue_from
        to_issue = relation.issue_to
        endpoint_attrs(base.merge(arrowhead: 'none'), from_issue: from_issue, to_issue: to_issue, dir: 'none')
      when 'blocks', 'precedes'
        direction = Cosmosys::DependencySettings.direction_for(relation_type)
        if direction == 'reverse'
          from_issue = relation.issue_to
          to_issue = relation.issue_from
        else
          from_issue = relation.issue_from
          to_issue = relation.issue_to
        end
        endpoint_attrs(base, from_issue: from_issue, to_issue: to_issue, dir: 'forward')
      else
        from_issue = relation.issue_from
        to_issue = relation.issue_to
        endpoint_attrs(base, from_issue: from_issue, to_issue: to_issue, dir: 'forward')
      end
    end

    def issue_url(issue)
      Rails.application.routes.url_helpers.issue_path(issue)
    end

    def cluster_id_for(issue)
      "cluster_issue_#{issue.id}"
    end

    def endpoint_attrs(base, from_issue:, to_issue:, dir:)
      from_endpoint = edge_endpoint(from_issue, other_issue: to_issue)
      to_endpoint = edge_endpoint(to_issue, other_issue: from_issue)

      attrs = base.merge(
        from: from_issue,
        to: to_issue,
        from_node_id: from_endpoint[:node_id],
        to_node_id: to_endpoint[:node_id],
        dir: dir
      )
      attrs[:ltail] = cluster_id_for(from_issue) if from_endpoint[:use_cluster_boundary]
      attrs[:lhead] = cluster_id_for(to_issue) if to_endpoint[:use_cluster_boundary]
      attrs
    end

    def edge_endpoint(issue, other_issue:)
      if cluster_title_issue?(issue)
        if internal_cluster_relation?(cluster_issue: issue, other_issue: other_issue)
          { node_id: title_node_id_for(issue), use_cluster_boundary: false }
        else
          # Use cluster gateway node for external relations (invisible node at cluster center)
          { node_id: gateway_node_id_for(issue), use_cluster_boundary: true }
        end
      elsif cluster_anchor_issue?(issue)
        # An anchor represents a node inside a cluster that has external relations.
        # The cluster boundary is used only if the relation goes OUTSIDE the cluster.
        # The cluster container is the immediate parent (the title issue).
        container_cluster_id = issue.parent_id
        other_is_in_same_container = (other_issue.id == container_cluster_id || other_issue.parent_id == container_cluster_id)

        if other_is_in_same_container
          { node_id: anchor_node_id_for(issue), use_cluster_boundary: false }
        else
          # Use cluster gateway node for external relations
          { node_id: gateway_node_id_for(issue), use_cluster_boundary: true }
        end
      else
        { node_id: node_id_for(issue, container: false), use_cluster_boundary: false }
      end
    end

    def internal_cluster_relation?(cluster_issue:, other_issue:)
      ancestor_ids = @ancestor_ids_by_issue[other_issue.id] || Set.new
      ancestor_ids.include?(cluster_issue.id)
    end

    def cluster_title_issue?(issue)
      @cluster_title_issue_ids.include?(issue.id)
    end

    def cluster_anchor_issue?(issue)
      @cluster_anchor_issue_ids.include?(issue.id)
    end

    def node_id_for(issue, container:)
      case container
      when true
        title_node_id_for(issue)
      when :anchor
        anchor_node_id_for(issue)
      else
        issue_node_id_for(issue)
      end
    end

    def issue_node_id_for(issue)
      "issue_#{issue.id}"
    end

    def title_node_id_for(issue)
      "cluster_title_issue_#{issue.id}"
    end

    def anchor_node_id_for(issue)
      "cluster_anchor_issue_#{issue.id}"
    end

    def gateway_node_id_for(issue)
      "cluster_gateway_issue_#{issue.id}"
    end

    def format_attrs(attrs)
      attrs.map { |key, value| %(#{key}="#{escape(value)}") }.join(', ')
    end

    def layout_attr
      @layout_mode == 'fdp' ? ' layout="fdp",' : ' '
    end

    def escape(value)
      value.to_s.gsub('\\', '\\\\').gsub('"', '\"').gsub("\n", '\\n')
    end

    def indent(lines, spaces)
      prefix = ' ' * spaces
      lines.map { |line| "#{prefix}#{line}" }
    end
  end
end
