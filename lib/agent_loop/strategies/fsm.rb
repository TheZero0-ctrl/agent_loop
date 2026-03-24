# frozen_string_literal: true

module AgentLoop
  module Strategies
    class Fsm < Base
      class InvalidTransition < StandardError; end

      STRATEGY_KEY = :__strategy__

      def initialize(transitions:, initial_step:)
        @transitions = transitions
        @initial_step = initial_step
      end

      def cmd(agent:, state:, instruction:, context:)
        step = current_step(state)
        allowed_actions = Array(@transitions.fetch(step, []))

        unless allowed_actions.include?(instruction.action)
          raise InvalidTransition, "Action #{instruction.action} not allowed from step #{step}"
        end

        result = agent.cmd(state, instruction, context: context)
        next_step = infer_next_step(step, instruction.action)

        state_ops = Array(result.state_ops) + [
          AgentLoop::StateOps::SetPath.new(path: [STRATEGY_KEY, :step], value: next_step)
        ]

        AgentLoop::Result.new(
          state: result.state,
          state_ops: state_ops,
          effects: result.effects,
          status: result.status,
          error: result.error
        )
      end

      private

      def current_step(state)
        (state || {}).dig(STRATEGY_KEY, :step) || @initial_step
      end

      def infer_next_step(current_step, action)
        action_step = action.to_s.sub(/^on_/, "").to_sym
        return action_step if @transitions.key?(action_step)

        current_step
      end
    end
  end
end
