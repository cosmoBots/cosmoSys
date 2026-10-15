module Cosmosys
  # Presents the combined diagram's selected model as a hierarchy-only view:
  # relation edges are omitted from the hierarchy layout. Container title
  # nodes become cluster labels, and direct leaf/container siblings are placed
  # in consecutive ranks.
  class HierarchyDiagramView
    TITLE_NODE = /^\s*cluster_title_issue_(\d+) \[label="((?:[^"\\]|\\.)*)".*\];\s*$/
    COMPACT_RANKSEP = '0.1'.freeze
    COMPACT_CLUSTER_MARGIN = '1'.freeze

    def self.from_combined(dot_body)
      new(dot_body).render
    end

    def initialize(dot_body)
      @lines = dot_body.to_s.lines.reject { |line| line.start_with?('// cosmosys:') }
      @cluster_labels = @lines.each_with_object({}) do |line, labels|
        match = line.match(TITLE_NODE)
        labels[match[1]] = match[2] if match
      end
      @sibling_layouts, @layout_anchor_issue_ids = sibling_layouts
    end

    def render
      current_clusters = []
      rendered = []

      @lines.each do |line|
        if (match = line.match(/^\s*subgraph "cluster_issue_(\d+)" \{$/))
          current_clusters << match[1]
        elsif line.strip == '}' && current_clusters.any?
          cluster_id = current_clusters.last
          rendered.concat(sibling_rank_lines(cluster_id))
          current_clusters.pop
        end

        line = transform_title_node(line)
        line = transform_cluster(line, current_clusters.last)
        line = compact_rank_separation(line)
        rendered << omit_relation_edge(line)
        if (match = line.match(/^\s*subgraph "cluster_issue_(\d+)" \{$/)) && @layout_anchor_issue_ids.include?(match[1])
          indent = line[/\A\s*/] + '  '
          rendered << %(#{indent}hierarchy_layout_anchor_issue_#{match[1]} [shape="point", style="invis", width="0.01", height="0.01", fixedsize=true, label=""];\n)
        end
      end

      rendered.join
    end

    private

    def transform_title_node(line)
      match = line.match(TITLE_NODE)
      return line unless match

      indent = line[/\A\s*/]
      %(#{indent}cluster_title_issue_#{match[1]} [label="", shape=point, style=invis, width=0.01, height=0.01, fixedsize=true];\n)
    end

    def transform_cluster(line, cluster_id)
      return line unless cluster_id && @cluster_labels.key?(cluster_id)

      line = if line.strip == 'label="";'
               line.sub('label=""', %(label="#{@cluster_labels.fetch(cluster_id)}"))
             else
               line
             end
      line.sub('margin="8"', %(margin="#{COMPACT_CLUSTER_MARGIN}"))
    end

    def omit_relation_edge(line)
      # Hierarchy is laid out exclusively from containment. Keeping hidden
      # relation edges from the combined graph can force incompatible ranks.
      return '' if line.match?(/\A\s*[^\/\n].*? -> .*?\[.*\];\s*\z/)

      line
    end

    # The combined renderer's ranksep leaves too much blank space between
    # hierarchy levels once the relation edges are removed. Keep the spacing
    # adjustment local to hierarchy diagrams; combined/dependency layouts are
    # unchanged.
    def compact_rank_separation(line)
      line.sub(/\branksep=[^,\s\]]+/, "ranksep=#{COMPACT_RANKSEP}")
    end

    # Hierarchy layout is structural and only applies to hierarchy diagrams.
    # Child issue nodes without their own cluster are the loose row; child
    # clusters are represented by an invisible anchor within each cluster and
    # form the container row below it. Empty groups add no rank or spacer.
    def sibling_layouts
      layouts = Hash.new { |hash, key| hash[key] = { loose: [], containers: [] } }
      stack = []
      @lines.each do |line|
        if (match = line.match(/^\s*subgraph "cluster_issue_(\d+)" \{$/))
          layouts[stack.last][:containers] << match[1] if stack.any?
          stack << match[1]
        elsif line.strip == '}' && stack.any?
          stack.pop
        elsif stack.any? && (match = line.match(/^\s*issue_(\d+) \[/))
          issue_id = match[1]
          layouts[stack.last][:loose] << issue_id unless issue_id == stack.last
        end
      end

      layouts.each_value do |groups|
        groups[:loose].uniq!
        groups[:containers].uniq!
      end
      # Every item cluster needs an anchor: its parent ranks this cluster
      # among the siblings, while the same anchor ranks this item's children.
      anchor_ids = layouts.keys
      [layouts, anchor_ids]
    end

    def sibling_rank_lines(cluster_id)
      groups = @sibling_layouts[cluster_id]
      return [] unless groups

      loose = groups[:loose].uniq.map { |issue_id| "issue_#{issue_id}" }
      containers = groups[:containers].uniq.map { |issue_id| "hierarchy_layout_anchor_issue_#{issue_id}" }
      return [] if loose.empty? && containers.empty?

      lines = []
      parent_anchor = "hierarchy_layout_anchor_issue_#{cluster_id}"
      lines << %(  { rank=same; #{loose.join('; ')}; }\n) if loose.length > 1 || (loose.any? && containers.any?)
      lines << %(  { rank=same; #{containers.join('; ')}; }\n) if containers.length > 1 || (loose.any? && containers.any?)
      lines << %(  #{parent_anchor} -> #{loose.first} [style="invis", dir="none", arrowhead="none", constraint=true, weight=40];\n) unless loose.empty?
      lines << %(  #{parent_anchor} -> #{containers.first} [style="invis", dir="none", arrowhead="none", constraint=true, weight=40];\n) unless containers.empty?
      if loose.any? && containers.any?
        lines << %(  #{loose.last} -> #{containers.first} [style="invis", dir="none", arrowhead="none", constraint=true, weight=40, minlen=1];\n)
      end
      lines
    end
  end
end
