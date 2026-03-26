# frozen_string_literal: true

module AgentLoop
  module Strategies
    class Base
      def init(agent_class:, context: {})
        _agent_class = agent_class
        _context = context
        :ok
      end

      def cmd(agent:, state:, instruction:, context:)
        raise NotImplementedError
      end

      def tick(instance:, runtime:, context: {})
        _instance = instance
        _runtime = runtime
        _context = context
        :noop
      end

      def snapshot(instance:)
        {
          strategy: self.class.name,
          instance_id: instance.id
        }
      end

      def signal_routes(_context = {})
        []
      end
    end
  end
end
