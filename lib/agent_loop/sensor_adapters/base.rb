# frozen_string_literal: true

module AgentLoop
  module SensorAdapters
    class Base
      def connect(_sensor_server, opts: {})
        _opts = opts
        :ok
      end

      def disconnect(_sensor_server)
        :ok
      end

      def subscribe(_sensor_server, topic:)
        _topic = topic
        :ok
      end

      def unsubscribe(_sensor_server, topic:)
        _topic = topic
        :ok
      end
    end
  end
end
