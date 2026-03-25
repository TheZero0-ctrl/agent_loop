# frozen_string_literal: true

module AgentLoop
  module Strategies
    class Base
      def cmd(agent:, state:, instruction:, context:)
        raise NotImplementedError
      end

      def signal_routes(_context = {})
        []
      end
    end
  end
end
