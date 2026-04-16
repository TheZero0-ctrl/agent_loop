# frozen_string_literal: true

module AgentLoop
  module Strategies
    class Direct < Base
      def cmd(agent:, state:, instructions:, context:)
        state_op_applicator = AgentLoop::StateOps::Applicator.new
        current_state = state
        state_ops = []
        effects = []
        status = :ok
        error = nil

        Array(instructions).each do |instruction|
          result = agent.cmd(current_state, instruction, context: context)
          current_state = state_op_applicator.apply_all(result.state, result.state_ops)
          state_ops.concat(Array(result.state_ops))
          effects.concat(Array(result.effects))
          status = result.status
          error = result.error
          break unless result.ok?
        end

        AgentLoop::Result.new(
          state: current_state,
          state_ops: state_ops,
          effects: effects,
          status: status,
          error: error
        )
      end
    end
  end
end
