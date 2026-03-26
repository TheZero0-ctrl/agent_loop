# frozen_string_literal: true

module AgentLoop
  module Effects
    class Schedule < Base
      attr_reader :delay_ms, :signal, :meta

      def initialize(delay_ms:, signal:, meta: {})
        @delay_ms = delay_ms
        @signal = signal
        @meta = meta
      end
    end
  end
end
