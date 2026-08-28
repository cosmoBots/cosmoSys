module Cosmosys
  class ProgressReporter
    def initialize(record, state: nil)
      @record = record
      @state = state
      @last_percent = nil
      @last_phase = nil
    end

    def call(percent, phase, details = {})
      percent = percent.to_i.clamp(0, 100)
      phase = phase.to_s
      return if percent == @last_percent && phase == @last_phase && details.empty?

      attributes = { summary: @record.summary.merge(details.stringify_keys).merge('progress' => percent, 'progress_phase' => phase) }
      attributes[:state] = @state if @state
      @record.update!(attributes)
      @last_percent = percent
      @last_phase = phase
    end
  end
end
