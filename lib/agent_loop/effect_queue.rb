# frozen_string_literal: true

module AgentLoop
  class EffectQueue
    def enqueue(effect:, instance:, context: {})
      raise NotImplementedError
    end

    def drain(runtime:, limit: nil)
      raise NotImplementedError
    end
  end
end
