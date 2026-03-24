# frozen_string_literal: true

module AgentLoop
  module Strategies
    class Direct < Base
      def cmd(agent:, state:, instruction:, context:)
        agent.cmd(state, instruction, context: context)
      end
    end
  end
end
