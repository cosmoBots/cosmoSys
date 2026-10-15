module Cosmosys
  # Presents the combined diagram's selected model as a hierarchy-only view:
  # relation edges remain in the Graphviz graph as layout constraints, but are
  # not drawn. Container title nodes become cluster labels, as in the legacy
  # hierarchy renderer.
  class HierarchyDiagramView
    TITLE_NODE = /^\s*cluster_title_issue_(\d+) \[label="((?:[^"\\]|\\.)*)".*\];\s*$/

    def self.from_combined(dot_body)
      new(dot_body).render
    end

    def initialize(dot_body)
      @lines = dot_body.to_s.lines.reject { |line| line.start_with?('// cosmosys:') }
      @cluster_labels = @lines.each_with_object({}) do |line, labels|
        match = line.match(TITLE_NODE)
        labels[match[1]] = match[2] if match
      end
    end

    def render
      current_clusters = []

      @lines.map do |line|
        if (match = line.match(/^\s*subgraph "cluster_issue_(\d+)" \{$/))
          current_clusters << match[1]
        elsif line.strip == '}' && current_clusters.any?
          current_clusters.pop
        end

        line = transform_title_node(line)
        line = transform_cluster(line, current_clusters.last)
        transform_edge(line)
      end.join
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
      line.sub('margin="8"', 'margin="2"')
    end

    def transform_edge(line)
      match = line.match(/\A(\s*[^\/\n].*? -> .*?\[)(.*)(\];\s*)\z/)
      return line unless match

      attributes = match[2].gsub(/(?:\A|,\s*)(?:style|dir|arrowhead|color|fontcolor|label)="(?:[^"\\]|\\.)*"/, '')
      attributes = attributes.gsub(/,\s*,+/, ',').sub(/\A,\s*/, '').sub(/,\s*\z/, '')
      attributes << ', ' unless attributes.empty?
      %(#{match[1]}#{attributes}style="invis", dir="none", arrowhead="none", color="transparent", fontcolor="transparent"#{match[3]})
    end
  end
end
