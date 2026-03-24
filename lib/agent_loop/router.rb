# frozen_string_literal: true

module AgentLoop
  class Router
    class RouteNotFound < StandardError; end

    def instruction_for(agent_class, signal)
      action_name = agent_class.routes.fetch(signal.type) do
        raise RouteNotFound, "No route for signal type: #{signal.type}"
      end

      Instruction.new(action: action_name, params: signal.data,
                      meta: { signal_id: signal.id, signal_type: signal.type })
    end
  end
end
