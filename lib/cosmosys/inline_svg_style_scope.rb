require 'nokogiri'

module Cosmosys
  # Inline SVG styles are document-wide in HTML. WaveDrom emits selectors such
  # as `text`, which can override presentation attributes on unrelated SVGs
  # (including Graphviz diagrams). Scope its rules to the WaveDrom SVG itself.
  class InlineSvgStyleScope
    def self.call(html)
      fragment = Nokogiri::HTML5.fragment(html.to_s)
      fragment.css('svg.WaveDrom style').each do |style|
        style.content = scope_stylesheet(style.text)
      end
      fragment.to_html
    end

    def self.scope_stylesheet(stylesheet)
      stylesheet.gsub(/(^|})\s*([^{}]+)\{/m) do |rule_start|
        boundary = Regexp.last_match(1)
        selectors = Regexp.last_match(2)
        next rule_start if selectors.strip.start_with?('@')

        scoped_selectors = split_selector_list(selectors).map do |selector|
          selector = selector.strip
          selector.start_with?('svg.WaveDrom') ? selector : "svg.WaveDrom #{selector}"
        end

        "#{boundary}#{scoped_selectors.join(', ')} {"
      end
    end
    private_class_method :scope_stylesheet

    def self.split_selector_list(selectors)
      result = []
      start = 0
      depth = 0
      quote = nil

      selectors.each_char.with_index do |character, index|
        if quote
          quote = nil if character == quote
        elsif character == '"' || character == "'"
          quote = character
        elsif character == '(' || character == '['
          depth += 1
        elsif character == ')' || character == ']'
          depth -= 1 if depth.positive?
        elsif character == ',' && depth.zero?
          result << selectors[start...index]
          start = index + 1
        end
      end

      result << selectors[start..]
      result
    end
    private_class_method :split_selector_list
  end
end
