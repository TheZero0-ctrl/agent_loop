# frozen_string_literal: true

module AgentLoop
  module SensorEffects
    class Disconnect < Base
      attr_reader :adapter

      def initialize(adapter:)
        @adapter = adapter
      end
    end
  end
end
