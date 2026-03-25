# frozen_string_literal: true

require_relative "../signal_queue"

module AgentLoop
  module SignalQueues
    class InMemory < AgentLoop::SignalQueue
      def initialize
        @queue = []
      end

      def enqueue(instance:, signal:, context: {})
        @queue << { instance: instance, signal: signal, context: context }
      end

      def drain(runtime:, limit: nil)
        processed = 0

        until @queue.empty?
          break if limit && processed >= limit

          entry = @queue.shift
          yield(entry)
          processed += 1
        end

        processed
      end
    end
  end
end
