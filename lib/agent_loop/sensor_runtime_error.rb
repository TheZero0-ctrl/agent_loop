# frozen_string_literal: true

module AgentLoop
  class SensorRuntimeError < StandardError
    attr_reader :code, :context

    def initialize(message, code:, context: {})
      super(message)
      @code = code
      @context = context
    end
  end
end
