# frozen_string_literal: true

module AgentLoop
  module Effects
    class Spawn < Base
      attr_reader :agent_class, :id, :initial_state

      def initialize(agent_class:, id:, initial_state: nil)
        @agent_class = agent_class
        @id = id
        @initial_state = initial_state
      end
    end
  end
end
