# frozen_string_literal: true

module AgentLoop
  module Strategies
    class Base
      def init(instance:, runtime:, context: {})
        _instance = instance
        _runtime = runtime
        _context = context
        AgentLoop::Result.new(state: instance.state, effects: [])
      end

      def cmd(agent:, state:, instructions:, context:)
        _agent = agent
        _state = state
        _instructions = instructions
        _context = context
        raise NotImplementedError
      end

      def tick(instance:, runtime:, context: {})
        _instance = instance
        _runtime = runtime
        _context = context
        :noop
      end

      def snapshot(instance:, context: {})
        _context = context
        {
          strategy: self.class.name,
          instance_id: instance.id
        }
      end

      def signal_routes(_context = {})
        [['agent_loop.strategy.tick', :strategy_tick, 100]]
      end
    end
  end
end
