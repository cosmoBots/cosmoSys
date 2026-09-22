module Cosmosys
  module GraphvizTextSupport
    TOOLTIP_MAX_BYTES = 512
    TOOLTIP_ELLIPSIS = '...'.freeze
    HTML_BREAK_PATTERN = /<br\s*\/?\s*>/i

    private

    def graphviz_tooltip(value)
      text = value.to_s.scrub
      break_match = HTML_BREAK_PATTERN.match(text)
      natural_end = break_match&.begin(0)
      truncated = natural_end ? text[0...natural_end] : text
      omitted = !natural_end.nil?

      if truncated.bytesize > TOOLTIP_MAX_BYTES
        truncated = truncated.byteslice(0, TOOLTIP_MAX_BYTES - TOOLTIP_ELLIPSIS.bytesize)
        truncated = truncated.byteslice(0, truncated.bytesize - 1) until truncated.valid_encoding?
        omitted = true
      end

      omitted ? "#{truncated}#{TOOLTIP_ELLIPSIS}" : truncated
    end
  end
end
