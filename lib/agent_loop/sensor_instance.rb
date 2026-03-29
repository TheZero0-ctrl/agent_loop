# frozen_string_literal: true

module AgentLoop
  class SensorInstance
    attr_reader :id, :sensor_class
    attr_accessor :state, :status, :metadata, :context

    def initialize(sensor_class:, id:, state: nil, status: :idle, context: {}, metadata: {})
      @sensor_class = sensor_class
      @id = id
      @state = state
      @status = status
      @context = context
      @metadata = metadata
    end
  end
end
