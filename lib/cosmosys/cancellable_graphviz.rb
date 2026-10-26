require 'open3'
require_relative 'render_cancellation'

module Cosmosys
  module CancellableGraphviz
    def self.capture(dot_body)
      return Open3.capture3('dot', '-Tsvg', stdin_data: dot_body) unless RenderCancellation.current

      RenderCancellation.check!
      # Own the process group; cancellation terminates and reaps only our
      # subprocess, including descendants, never a PID received from a client.
      Open3.popen3('dot', '-Tsvg', pgroup: true) do |input, output, errors, waiter|
        readers = [Thread.new { output.read }, Thread.new { errors.read }]
        writer = Thread.new do
          input.write(dot_body)
        rescue Errno::EPIPE, IOError
          nil
        ensure
          input.close rescue nil
        end
        begin
          until waiter.join(0.05) && readers.none?(&:alive?) && !writer.alive?
            RenderCancellation.check!
          end
          writer.value
          completed = true
          [readers[0].value, readers[1].value, waiter.value]
        ensure
          unless completed
            signal_group('TERM', waiter.pid)
            waiter.join(0.25)
            signal_group('KILL', waiter.pid)
          end
          waiter.join
          input.close rescue nil
          writer.join
          readers.each(&:join)
        end
      end
    end

    def self.signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
