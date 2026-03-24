# frozen_string_literal: true

require_relative "../state_store"

module AgentLoop
  module StateStores
    class InMemory < StateStore
      def initialize
        @data = {}
      end

      def load(instance_id)
        @data[instance_id]
      end

      def save(instance_id, state)
        @data[instance_id] = state
      end

      def delete(instance_id)
        @data.delete(instance_id)
      end
    end
  end
end
