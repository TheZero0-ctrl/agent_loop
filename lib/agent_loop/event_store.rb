# frozen_string_literal: true

module AgentLoop
  class EventStore
    def append(_instance_id, _event)
      raise NotImplementedError
    end

    def read(_instance_id, from: nil)
      raise NotImplementedError
    end
  end
end
