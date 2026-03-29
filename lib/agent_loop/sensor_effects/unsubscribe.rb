# frozen_string_literal: true

module AgentLoop
  module SensorEffects
    class Unsubscribe < Base
      attr_reader :topic, :adapter

      def initialize(topic:, adapter: nil)
        @topic = topic
        @adapter = adapter
      end
    end
  end
end
