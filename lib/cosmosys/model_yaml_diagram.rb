require 'nokogiri'
require 'digest'
require_relative 'model_yaml_preview'

module Cosmosys
  # A static server-rendered diagram works in formatted text and report export.
  # Only a small Graphviz SVG vocabulary crosses the HTML-safe boundary.
  class ModelYamlDiagram
    ELEMENTS = %w[svg g polygon polyline path ellipse circle rect line text tspan title].freeze
    ATTRIBUTES = %w[id class width height viewBox version preserveAspectRatio transform
                    fill fill-opacity stroke stroke-width stroke-opacity stroke-dasharray
                    stroke-linecap stroke-linejoin points d x y cx cy rx ry x1 y1 x2 y2
                    font-family font-size font-weight font-style text-anchor].freeze

    def self.render(source, instance_id: 1)
      raise ArgumentError, 'Invalid diagram instance' unless instance_id.is_a?(Integer) && instance_id.positive?
      document = Cosmosys::ModelYamlDocument.new(source)
      output = Cosmosys::ModelYamlPreview.new(document).svg
      svg = Nokogiri::XML(output) { |config| config.strict.nonet }.root
      # Stable for the same source/order, unlike random IDs which would bust
      # cosmoSys report artifact caches on every otherwise identical request.
      prefix = "cosmosys-yaml-#{Digest::SHA256.hexdigest(source.to_s)[0, 16]}-#{instance_id}-"
      ([svg] + svg.css('*').to_a).each do |node|
        # Graphviz wraps tooltip/link geometry in SVG anchors. Discard the
        # interactive wrapper, not the paths and arrowheads inside it. Children
        # remain in this traversal and undergo the same allowlist checks.
        if node.name == 'a' && [nil, 'http://www.w3.org/2000/svg'].include?(node.namespace&.href)
          node.replace(node.children)
          next
        end
        unless ELEMENTS.include?(node.name) && [nil, 'http://www.w3.org/2000/svg'].include?(node.namespace&.href)
          node.remove
          next
        end
        node.attribute_nodes.each do |attribute|
          attribute.remove unless attribute.namespace.nil? && ATTRIBUTES.include?(attribute.name) && !attribute.value.match?(/url\s*\(/i)
        end
        node['id'] = "#{prefix}#{node['id']}" if node['id']
      end
      svg['class'] = 'cosmosys-yaml-diagram'
      svg['style'] = 'max-width:100%;height:auto'
      svg['role'] = 'img'
      svg['aria-label'] = 'cosmoSys diagram'
      svg.to_xml
    end
  end
end
