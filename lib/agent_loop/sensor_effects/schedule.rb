# frozen_string_literal: true

module AgentLoop
  module SensorEffects
    class Schedule < Base
      attr_reader :delay_ms, :event

      def initialize(delay_ms:, event: :tick)
        @delay_ms = Integer(delay_ms)
        @event = event
      end
    end
  end
end
