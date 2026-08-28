module Cosmosys
  class MainReportTextNormalizer
    def self.normalize(text)
      return '' if text.blank?

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
  end
end
