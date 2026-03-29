# frozen_string_literal: true

module AgentLoop
  module SensorEffects
    class Executor
      def execute(effect, sensor_server:)
        case effect
        when AgentLoop::SensorEffects::Emit
          sensor_server.deliver_signal(effect.signal, target: effect.target)
        when AgentLoop::SensorEffects::Schedule
          sensor_server.schedule_event(delay_ms: effect.delay_ms, event: effect.event)
        when AgentLoop::SensorEffects::Connect
          sensor_server.adapter_for(effect.adapter).connect(sensor_server, opts: effect.opts)
        when AgentLoop::SensorEffects::Disconnect
          sensor_server.adapter_for(effect.adapter).disconnect(sensor_server)
        when AgentLoop::SensorEffects::Subscribe
          sensor_server.adapter_for(effect.adapter).subscribe(sensor_server, topic: effect.topic)
        when AgentLoop::SensorEffects::Unsubscribe
          sensor_server.adapter_for(effect.adapter).unsubscribe(sensor_server, topic: effect.topic)
        else
          raise AgentLoop::SensorRuntimeError.new(
            "Unsupported sensor effect: #{effect.class}",
            code: :unsupported_sensor_effect
          )
        end
      end
    end
  end
end
