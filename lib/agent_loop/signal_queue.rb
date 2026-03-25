# frozen_string_literal: true

module AgentLoop
  class SignalQueue
    def enqueue(instance:, signal:, context: {})
      raise NotImplementedError
    end

    def drain(runtime:, limit: nil)
      raise NotImplementedError
    end
  end
end
