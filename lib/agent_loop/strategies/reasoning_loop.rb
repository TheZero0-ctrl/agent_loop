# frozen_string_literal: true

module AgentLoop
  module Strategies
    class ReasoningLoop < Base
      STRATEGY_KEY = :__strategy__
      LOOP_KEY = :reasoning_loop

      def initialize(tick_delay_ms: 25)
        @tick_delay_ms = tick_delay_ms
      end

      private

      attr_reader :tick_delay_ms

      def strategy_state(state)
        ((state || {}).dig(STRATEGY_KEY, LOOP_KEY) || {}).transform_keys(&:to_sym)
      end

      def merge_strategy_state_ops(attributes)
        attributes.map do |key, value|
          AgentLoop::StateOps::SetPath.new(path: [STRATEGY_KEY, LOOP_KEY, key], value: value)
        end
      end

      def schedule_tick_effect(context, source: 'agent_loop://strategy/reasoning_loop')
        signal = AgentLoop::Signal.new(
          type: 'agent_loop.strategy.tick',
          source: source,
          data: {},
          metadata: {
            trace_id: context[:trace_id],
            correlation_id: context[:correlation_id]
          }.compact
        )
        AgentLoop::Effects::Schedule.new(delay_ms: tick_delay_ms, signal: signal)
      end
    end
  end
end
