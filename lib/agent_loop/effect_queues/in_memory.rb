# frozen_string_literal: true

require_relative '../effect_queue'

module AgentLoop
  module EffectQueues
    class InMemory < AgentLoop::EffectQueue
      def initialize
        @queue = []
      end

      def enqueue(effect:, instance:, context: {})
        @queue << { effect: effect, instance: instance, context: context }
      end

      def drain(runtime:, limit: nil)
        _runtime = runtime
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
