module Cosmosys
  module ImageGap
    DATA_URL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVQI12NgAAIAAAUAAeImBZsAAAAASUVORK5CYII='.freeze
    MAX_WIDTH_PX = 2000

    def self.width_px(value)
      match = value.to_s.strip.downcase.match(/\A(\d+(?:\.\d+)?)\s*(px|cm|mm)?\z/)
      raise ArgumentError unless match

      factor = { 'px' => 1.0, 'cm' => 96.0 / 2.54, 'mm' => 96.0 / 25.4 }.fetch(match[2] || 'px')
      width = match[1].to_f * factor
      raise ArgumentError unless width.finite? && width.positive? && width <= MAX_WIDTH_PX

      [width.round, 1].max
    end
  end
end
