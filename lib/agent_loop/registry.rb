# frozen_string_literal: true

require 'concurrent/map'

module AgentLoop
  class Registry
    class << self
      def register(id, server)
        servers[id] = server
        server
      end

      def unregister(id)
        servers.delete(id)
      end

      def whereis(id)
        servers[id]
      end

      def clear
        servers.clear
      end

      private

      def servers
        @servers ||= Concurrent::Map.new
      end
    end
  end
end
