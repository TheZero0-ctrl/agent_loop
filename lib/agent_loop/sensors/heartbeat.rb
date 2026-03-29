# frozen_string_literal: true

module AgentLoop
  module Sensors
    class Heartbeat
      include AgentLoop::Sensor

      name 'heartbeat_sensor'
      description 'Emits heartbeat signals at an interval'

      schema do
        required(:interval_ms).filled(:integer)
        optional(:message).filled(:string)
      end

      def init(config, context: {})
        {
          interval_ms: config.fetch(:interval_ms),
          message: config.fetch(:message, 'heartbeat'),
          agent_ref: context[:agent_ref]
        }
      end

      def handle_event(event, state, context: {})
        _context = context
        return [:ok, state] unless event.to_sym == :tick

        signal = AgentLoop::Signal.new(
          type: 'agent_loop.sensor.heartbeat',
          source: "/sensor/#{self.class.name}",
          data: {
            message: state.fetch(:message),
            timestamp: Time.now.utc.to_s
          }
        )

        [:ok, state, [[:emit, signal], [:schedule, state.fetch(:interval_ms), :tick]]]
      end
    end
  end
end
