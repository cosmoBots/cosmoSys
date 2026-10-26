require 'open3'
require_relative 'graphviz_text_support'
require_relative 'cancellable_graphviz'

module Cosmosys
  class HierarchyDiagramRenderer
    include Cosmosys::GraphvizTextSupport

    CURRENT_ISSUE_HIGHLIGHT = '#2F6FDE'.freeze

    def initialize(current_issue: nil)
      @current_issue = current_issue
    end

    def build_graph(title:)
      lines = []
      lines << %(digraph #{title} {)
      lines << '  graph [bgcolor="transparent", margin=0, pad=0.5, rankdir=TB, nodesep=0.3, ranksep=0.3, compound=true, pack=1, overlap=false, mclimit=10];'
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

      rank_lines = sibling_rank_constraints(children)
      rank_anchor_lines = hierarchy_rank_anchor_constraints(issue, children)
      build_issue_box(issue, nested_lines: nested_lines + rank_lines + rank_anchor_lines, boundary: boundary)
    end

    def render_svg(dot_body)
      stdout, stderr, status = CancellableGraphviz.capture(dot_body)
      raise "Graphviz dot failed: #{stderr.presence || 'unknown error'}" unless status.success?

      stdout.sub(/\A.*?<svg/m, '<svg')
    end

    def node_signature(issue, boundary: false)
      attrs = issue_node_attrs(issue, boundary: boundary)
      [issue.id, boundary ? 1 : 0, attrs[:label], attrs[:shape], attrs[:fillcolor], attrs[:color],
       attrs[:fontcolor], attrs[:fontname], attrs[:margin], issue.cosmosys_diagram_sibling_rank('hierarchy'),
       attrs[:penwidth]].join(':')
    end

    def cluster_signature(issue, boundary: false)
      attrs = cluster_attrs(issue, boundary: boundary)
      [issue.id, boundary ? 1 : 0, attrs[:label], attrs[:color], attrs[:fillcolor], attrs[:fontname], attrs[:penwidth]].join(':')
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
      lines << %(  fillcolor="#{escape(attrs[:fillcolor])}";) if attrs[:fillcolor].present?
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
        tooltip: graphviz_tooltip(issue.description),
        fontsize: 10,
        margin: issue.cosmosys_diagram_node_margin('hierarchy'),
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
        style: issue.cosmosys_hierarchy_cluster_fill_color.present? ? 'filled' : 'solid',
        fillcolor: issue.cosmosys_hierarchy_cluster_fill_color,
        URL: issue_url(issue),
        tooltip: graphviz_tooltip(issue.description)
      }

      if @current_issue && issue.id == @current_issue.id
        highlight = issue.cosmosys_diagram_valid? ? CURRENT_ISSUE_HIGHLIGHT : 'red'
        attrs[:color] = highlight
        attrs[:pencolor] = highlight
        attrs[:penwidth] = issue.cosmosys_hierarchy_cluster_penwidth(selected: true)
      end

      attrs
    end

    def sibling_rank_constraints(children)
      groups = children.filter_map do |entry|
        issue = entry.fetch(:issue)
        rank = issue.cosmosys_diagram_sibling_rank('hierarchy')
        [rank, entry] unless rank.nil?
      end.group_by(&:first).sort_by(&:first)
      return [] if groups.length < 2

      rank_groups = groups.map do |_rank, ranked_issues|
        ids = ranked_issues.map { |_rank_value, entry| rank_node_id(entry) }
        "{ rank=same; #{ids.join('; ')}; };"
      end
      # Invisible constrained edges order semantic rows without adding visible dependencies.
      invisible_edges = groups.each_cons(2).map do |(_upper_rank, upper_issues), (_lower_rank, lower_issues)|
        from = rank_node_id(upper_issues.first.last)
        to = rank_node_id(lower_issues.first.last)
        "#{from} -> #{to} [style=invis, arrowhead=none];"
      end

      rank_groups + invisible_edges
    end

    # A child that is itself a cluster has no visible Graphviz node to rank with
    # its siblings. Give ranked clusters an invisible anchor inside the cluster,
    # and keep that anchor above the cluster's own first ranked row.
    def hierarchy_rank_anchor_constraints(issue, children)
      return [] if children.empty? || issue.cosmosys_diagram_sibling_rank('hierarchy').nil?

      anchor = rank_anchor_id(issue)
      ranked_children = children.filter_map do |entry|
        child_issue = entry.fetch(:issue)
        rank = child_issue.cosmosys_diagram_sibling_rank('hierarchy')
        [rank, entry] unless rank.nil?
      end.group_by(&:first).sort_by(&:first)
      return [%(#{anchor} [label="", shape=point, width=0.01, height=0.01, style=invis];)] if ranked_children.empty?

      first_row = ranked_children.first.last.map { |_rank, entry| rank_node_id(entry) }
      [%(#{anchor} [label="", shape=point, width=0.01, height=0.01, style=invis];),
       %(#{anchor} -> #{first_row.first} [style=invis, arrowhead=none];)]
    end

    def rank_node_id(entry)
      issue = entry.fetch(:issue)
      Array(entry[:children]).empty? ? node_id_for(issue) : rank_anchor_id(issue)
    end

    def rank_anchor_id(issue)
      "hierarchy_rank_anchor_issue_#{issue.id}"
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
