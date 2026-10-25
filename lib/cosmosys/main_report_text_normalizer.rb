module Cosmosys
  class MainReportTextNormalizer
    # Standalone characterization has no ApplicationHelper. In Redmine use its
    # actual macro grammar, so report preprocessing preserves the same blocks
    # that textilizable will subsequently execute (including escaped macros).
    MACRO_RE = /!?\{\{\w+(?:\([^\n\r]*?\))?(?:[\n\r].*?[\n\r])?\}\}/m.freeze

    def self.normalize(text)
      return '' if text.blank?

      source = text.to_s
      prefix = "\0COSMOSYS_REPORT_MACRO_"
      prefix += '_' while source.include?(prefix)
      macros = {}
      pattern = defined?(ApplicationHelper::MACROS_RE) ? ApplicationHelper::MACROS_RE : MACRO_RE
      masked = source.gsub(pattern) do |macro|
        token = "#{prefix}#{macros.size}\0"
        macros[token] = macro
        token
      end
      normalized = normalize_prose(masked)
      return normalized if macros.empty?

      normalized.gsub(/#{Regexp.escape(prefix)}\d+\0/) { |token| macros.fetch(token) }
    end

    def self.normalize_prose(text)
      chars = text.to_s.each_char
      result = +''
      previous_char = nil
      new_line = false

      chars.each do |char|
        if previous_char == "\n"
          unless new_line
            if char == "\r" || char == "\n" || char == '-' || char == '|' || char.to_i.to_s == char
              new_line = true
            else
              result << "\r\n"
            end
          else
            new_line = false if char != "\r" && char != "\n"
          end
        end

        result << char
        previous_char = char
      end

      result
    end
    private_class_method :normalize_prose
  end
end
