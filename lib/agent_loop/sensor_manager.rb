# frozen_string_literal: true

module AgentLoop
  class SensorManager
    def initialize(registry: AgentLoop::SensorRegistry)
      @registry = registry
    end

    def start(sensor:, config: {}, context: {}, id: nil, sensor_instance: nil,
              max_event_queue_size: AgentLoop::SensorServer::DEFAULT_MAX_QUEUE_SIZE,
              max_effect_queue_size: AgentLoop::SensorServer::DEFAULT_MAX_QUEUE_SIZE,
              effect_executor: AgentLoop::SensorEffects::Executor.new)
      AgentLoop::SensorServer.start(
        sensor: sensor,
        config: config,
        context: context,
        id: id,
        sensor_instance: sensor_instance,
        registry: registry,
        max_event_queue_size: max_event_queue_size,
        max_effect_queue_size: max_effect_queue_size,
        effect_executor: effect_executor
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
