# frozen_string_literal: true

module AgentLoop
  class Instance
    attr_reader :id, :agent_class
    attr_accessor :state, :status, :children, :metadata

    def initialize(agent_class:, id:, state: nil, status: :idle, children: {}, metadata: {})
      @agent_class = agent_class
      @id = id
      @state = state
      @status = status
      @children = children
      @metadata = metadata
    end
  end
end
