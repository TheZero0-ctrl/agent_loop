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

      def cmd(agent:, state:, instructions:, context:)
        state_op_applicator = AgentLoop::StateOps::Applicator.new
        current_state = state
        current_step_value = current_step(current_state)
        accumulated_state_ops = []
        accumulated_effects = []
        status = :ok
        error = nil

        Array(instructions).each do |instruction|
          allowed_actions = Array(@transitions.fetch(current_step_value, []))

          unless allowed_actions.include?(instruction.action)
            raise InvalidTransition,
                  "Action #{instruction.action} not allowed from step #{current_step_value}"
          end

          result = agent.cmd(current_state, instruction, context: context)
          next_step = infer_next_step(current_step_value, instruction.action)
          step_op = AgentLoop::StateOps::SetPath.new(path: [STRATEGY_KEY, :step], value: next_step)
          step_state_ops = Array(result.state_ops) + [step_op]

          current_state = state_op_applicator.apply_all(result.state, step_state_ops)
          current_step_value = next_step
          accumulated_state_ops.concat(step_state_ops)
          accumulated_effects.concat(Array(result.effects))
          status = result.status
          error = result.error
          break unless result.ok?
        end

        AgentLoop::Result.new(
          state: current_state,
          state_ops: accumulated_state_ops,
          effects: accumulated_effects,
          status: status,
          error: error
        )
      end

      private

      def current_step(state)
        (state || {}).dig(STRATEGY_KEY, :step) || @initial_step
      end

      def infer_next_step(current_step, action)
        action_step = action.to_s.sub(/^on_/, '').to_sym
        return action_step if @transitions.key?(action_step)

        current_step
      end
    end
  end
end
