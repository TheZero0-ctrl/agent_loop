# frozen_string_literal: true

require 'concurrent/map'

module AgentLoop
  class SensorRegistry
    class << self
      def register(id, server)
        sensors[id] = server
        server
      end

      def unregister(id)
        sensors.delete(id)
      end

      def whereis(id)
        sensors[id]
      end

      def clear
        sensors.clear
      end

      private

      def sensors
        @sensors ||= Concurrent::Map.new
      end
    end
  end
end
