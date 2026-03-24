# frozen_string_literal: true

module AgentLoop
  module Effects
    class Schedule < Base
      attr_reader :delay_ms, :signal

      def initialize(delay_ms:, signal:)
        @delay_ms = delay_ms
        @signal = signal
      end
    end
  end
end
