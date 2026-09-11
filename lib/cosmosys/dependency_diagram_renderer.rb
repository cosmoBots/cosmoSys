require 'open3'

module Cosmosys
  class DependencyDiagramRenderer
    CURRENT_ISSUE_HIGHLIGHT = '#2F6FDE'.freeze

    def initialize(current_issue: nil)
      @current_issue = current_issue
    end

    def build_graph(title:, rankdir:)
      lines = []
      lines << %(digraph #{title} {)
      lines << %(  graph [bgcolor="transparent", margin=0, pad=0.1, rankdir=#{rankdir}, nodesep=0.3, ranksep=0.4, splines=true, compound=true];)
      lines << '  node [shape=record, style="filled", fontname="times", fontsize=10, margin="0.03,0.03", width=0, height=0, penwidth=0.5];'
      lines << '  subgraph "cluster_diagram_root" {'
      lines << '    label="";'
      lines << '    color="#d9d9d9";'
      lines << '    pencolor="#d9d9d9";'
      lines << '    penwidth="0.4";'
      lines << '    margin="0";'
      yield lines
      lines << '  }'
      lines << '}'
      lines.join("\n")
    end

    def build_node(issue, boundary: false, dependency_container: nil, namespace: nil)
      [%(#{node_id_for(issue, namespace: namespace)} [#{format_attrs(node_attrs(issue, boundary: boundary, dependency_container: dependency_container))}];)]
    end

    def build_edge(relation, namespace: nil)
      attrs = edge_attrs(relation)
      return [] if attrs.blank?

      [%(#{node_id_for(attrs.fetch(:from), namespace: namespace)} -> #{node_id_for(attrs.fetch(:to), namespace: namespace)} [#{format_attrs(attrs.except(:from, :to))}];)]
    end

    def build_subtree_cluster(issue, label:)
      lines = []
      lines << %(subgraph "cluster_dependency_subtree_#{issue.id}" {)
      lines << %(  label="#{escape(label)}";)
      lines << '  labelloc="t";'
      lines << '  labeljust="l";'
      lines << '  color="#e58b2a";'
      lines << '  pencolor="#e58b2a";'
      lines << '  fontcolor="#a64f00";'
      lines << '  penwidth="1.2";'
      lines << '  style="rounded";'
      lines << '  margin="12";'
      lines << %(  subtree_anchor_#{issue.id} [shape="point", width="0.01", height="0.01", label="", style="invis"];)
      yield lines
      lines << '}'
      lines
    end

    def build_subtree_zoom_edge(issue)
      [%(#{node_id_for(issue, namespace: 'context')} -> subtree_anchor_#{issue.id} [style="dashed", dir="none", arrowhead="none", color="#e58b2a", penwidth="0.9", lhead="cluster_dependency_subtree_#{issue.id}", constraint="true"];)]
    end

    def build_document_reference(catalog_ref, emit_node: true, namespace: nil)
      lines = []
      lines << %(#{document_node_id_for(catalog_ref)} [#{format_attrs(document_node_attrs(catalog_ref))}];) if emit_node
      lines << %(#{node_id_for(catalog_ref.issue, namespace: namespace)} -> #{document_node_id_for(catalog_ref)} [#{format_attrs(document_edge_attrs(catalog_ref))}];)
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

    def node_signature(issue, boundary: false, dependency_container: nil)
      attrs = node_attrs(issue, boundary: boundary, dependency_container: dependency_container)
      [
        issue.id,
        boundary ? 1 : 0,
        attrs[:label],
        attrs[:shape],
        attrs[:fillcolor],
        attrs[:color],
        attrs[:fontcolor],
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

    def document_node_id_for(catalog_ref)
      "document_catalog_entry_#{catalog_ref.document_catalog_entry_id}"
    end

    def node_attrs(issue, boundary:, dependency_container: nil)
      attrs = {
        label: issue.cosmosys_diagram_node_label(
          'dependency',
          boundary: boundary,
          dependency_container: dependency_container
        ),
        fillcolor: issue.cosmosys_diagram_fill_color('dependency'),
        color: issue.cosmosys_diagram_border_color('dependency'),
        fontcolor: issue.cosmosys_diagram_font_color('dependency'),
        fontname: issue.cosmosys_diagram_font_name('dependency', boundary: boundary),
        shape: issue.cosmosys_diagram_shape('dependency'),
        URL: issue_url(issue),
        target: '_top',
        tooltip: issue.description.to_s,
        fontsize: 10,
        margin: '0.03,0.03',
        width: 0,
        height: 0,
        penwidth: issue.cosmosys_diagram_penwidth('dependency')
      }

      if @current_issue && issue.id == @current_issue.id
        attrs[:penwidth] = issue.cosmosys_diagram_penwidth('dependency', selected: true)
        attrs[:color] = issue.cosmosys_diagram_valid? ? CURRENT_ISSUE_HIGHLIGHT : 'red'
      end

      attrs
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
        base.merge(from: relation.issue_from, to: relation.issue_to, dir: 'none', arrowhead: 'none')
      when 'blocks', 'precedes'
        direction = Cosmosys::DependencySettings.direction_for(relation_type)
        if direction == 'reverse'
          base.merge(from: relation.issue_to, to: relation.issue_from, dir: 'forward')
        else
          base.merge(from: relation.issue_from, to: relation.issue_to, dir: 'forward')
        end
      else
        base.merge(from: relation.issue_from, to: relation.issue_to, dir: 'forward')
      end
    end

    def issue_url(issue)
      Rails.application.routes.url_helpers.issue_path(issue)
    end

    def node_id_for(issue, namespace: nil)
      [namespace, "issue_#{issue.id}"].compact_blank.join('_')
    end

    def format_attrs(attrs)
      attrs.map { |key, value| %(#{key}="#{escape(value)}") }.join(', ')
    end

    def escape(value)
      value.to_s.gsub('\\', '\\\\').gsub('"', '\"').gsub("\n", '\\n')
    end
  end
end
