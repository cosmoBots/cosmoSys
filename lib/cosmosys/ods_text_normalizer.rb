require 'nokogiri'

module Cosmosys
  class OdsTextNormalizer
    Result = Struct.new(:text, :repairs, keyword_init: true)

    def self.call(value)
      original = value.to_s
      repairs = []
      text = original.gsub('<text:s/>', ' ')
      repairs << 'odf_space' if text != original
      replaced = text.gsub(/<text:s\s+text:c="(\d+)"\s*\/>/) { ' ' * Regexp.last_match(1).to_i }
      repairs << 'odf_repeated_space' if replaced != text
      text = replaced
      replaced = text.gsub('<text:line-break/>', "\n")
      repairs << 'odf_line_break' if replaced != text
      text = replaced
      if text.match?(/<[^>]+>/)
        decoded = Nokogiri::HTML.fragment(text).text
        repairs << 'html_fragment' if decoded != text
        text = decoded
      end
      replaced = text.gsub(/\r\n?/, "\n")
      repairs << 'line_endings' if replaced != text
      text = replaced
      replaced = text.unicode_normalize(:nfc)
      repairs << 'unicode_nfc' if replaced != text
      text = replaced
      replaced = text.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/, '')
      repairs << 'control_characters' if replaced != text
      Result.new(text: replaced, repairs: repairs.uniq)
    end
  end
end
