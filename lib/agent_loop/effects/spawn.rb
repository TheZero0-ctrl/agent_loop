# frozen_string_literal: true

module AgentLoop
  module Effects
    class Spawn < Base
      attr_reader :agent_class, :id, :initial_state, :tag, :on_parent_death

      def initialize(agent_class:, id:, initial_state: nil, tag: nil, on_parent_death: :stop)
        @agent_class = agent_class
        @id = id
        @initial_state = initial_state
        @tag = tag || id
        @on_parent_death = on_parent_death
      end
    end
  end
end
