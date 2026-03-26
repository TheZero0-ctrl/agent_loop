# frozen_string_literal: true

module AgentLoop
  class ServerManager
    def initialize(registry: AgentLoop::Registry)
      @registry = registry
    end

    def start(runtime:, instance: nil, agent_class: nil, id: nil, initial_state: nil,
              max_signal_queue_size: AgentLoop::AgentServer::DEFAULT_MAX_QUEUE_SIZE,
              max_effect_queue_size: AgentLoop::AgentServer::DEFAULT_MAX_QUEUE_SIZE)
      AgentLoop::AgentServer.start(
        runtime: runtime,
        instance: instance,
        agent_class: agent_class,
        id: id,
        initial_state: initial_state,
        registry: registry,
        max_signal_queue_size: max_signal_queue_size,
        max_effect_queue_size: max_effect_queue_size
      )
    end

    def stop(server, reason: nil)
      return :ok unless server

      server.stop(reason: reason)
    end

    def whereis(id)
      registry.whereis(id)
    end

    private

    attr_reader :registry
  end
end
