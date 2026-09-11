require 'open3'

module Cosmosys
  class HierarchyDiagramRenderer
    CURRENT_ISSUE_HIGHLIGHT = '#2F6FDE'.freeze

    def initialize(current_issue: nil)
      @current_issue = current_issue
    end

    def build_graph(title:)
      lines = []
      lines << %(digraph #{title} {)
      lines << '  graph [bgcolor="transparent", margin=0, pad=0.5, rankdir=TB, nodesep=0.5, ranksep=0.3, compound=true, pack=1, overlap=false, mclimit=10];'
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

    def build_tree(entry)
      issue = entry.fetch(:issue)
      boundary = entry[:boundary] == true
      children = Array(entry[:children])
      nested_lines = children.flat_map { |child| build_tree(child) }

      build_issue_box(issue, nested_lines: nested_lines, boundary: boundary)
    end

    def render_svg(dot_body)
      stdout, stderr, status = Open3.capture3('dot', '-Tsvg', stdin_data: dot_body)
      raise "Graphviz dot failed: #{stderr.presence || 'unknown error'}" unless status.success?

      stdout.sub(/\A.*?<svg/m, '<svg')
    end

    def node_signature(issue, boundary: false)
      attrs = issue_node_attrs(issue, boundary: boundary)
      [issue.id, boundary ? 1 : 0, attrs[:label], attrs[:shape], attrs[:fillcolor], attrs[:color],
       attrs[:fontcolor], attrs[:fontname], attrs[:penwidth]].join(':')
    end

    def cluster_signature(issue, boundary: false)
      attrs = cluster_attrs(issue, boundary: boundary)
      [issue.id, boundary ? 1 : 0, attrs[:label], attrs[:color], attrs[:fontname], attrs[:penwidth]].join(':')
    end

    private

    def build_issue_box(issue, nested_lines:, boundary:)
      return build_issue_node(issue, boundary: boundary) if nested_lines.blank?

      attrs = cluster_attrs(issue, boundary: boundary)
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
      lines.concat(indent(nested_lines, 2))
      lines << '}'
      lines
    end

    def build_issue_node(issue, boundary:)
      attrs = issue_node_attrs(issue, boundary: boundary)

      [%(#{node_id_for(issue)} [#{format_attrs(attrs)}];)]
    end

    def issue_node_attrs(issue, boundary:)
      attrs = {
        label: issue.cosmosys_diagram_node_label('hierarchy', boundary: boundary),
        fillcolor: issue.cosmosys_diagram_fill_color('hierarchy'),
        color: issue.cosmosys_diagram_border_color('hierarchy'),
        fontcolor: issue.cosmosys_diagram_font_color('hierarchy'),
        fontname: issue.cosmosys_diagram_font_name('hierarchy', boundary: boundary),
        shape: issue.cosmosys_diagram_shape('hierarchy'),
        URL: issue_url(issue),
        target: '_top',
        tooltip: issue.description.to_s,
        fontsize: 10,
        margin: '0.03,0.03',
        width: 0,
        height: 0,
        penwidth: issue.cosmosys_diagram_penwidth('hierarchy')
      }

      if @current_issue && issue.id == @current_issue.id
        attrs[:penwidth] = issue.cosmosys_diagram_penwidth('hierarchy', selected: true)
        attrs[:color] = issue.cosmosys_diagram_valid? ? CURRENT_ISSUE_HIGHLIGHT : 'red'
      end

      attrs
    end

    def cluster_attrs(issue, boundary:)
      attrs = {
        label: issue.cosmosys_hierarchy_cluster_label(boundary: boundary),
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

    def issue_url(issue)
      Rails.application.routes.url_helpers.issue_path(issue)
    end

    def cluster_id_for(issue)
      "cluster_issue_#{issue.id}"
    end

    def node_id_for(issue)
      "issue_#{issue.id}"
    end

    def format_attrs(attrs)
      attrs.map { |key, value| %(#{key}="#{escape(value)}") }.join(', ')
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
