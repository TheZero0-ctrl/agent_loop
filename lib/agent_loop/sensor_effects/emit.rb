# frozen_string_literal: true

module AgentLoop
  module SensorEffects
    class Emit < Base
      attr_reader :signal, :target

      def initialize(signal:, target: nil)
        @signal = signal
        @target = target
      end
    end
  end
end
