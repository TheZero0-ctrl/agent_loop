# frozen_string_literal: true

module AgentLoop
  class StateStore
    def load(_instance_id)
      raise NotImplementedError
    end

    def save(_instance_id, _state)
      raise NotImplementedError
    end

    def delete(_instance_id)
      raise NotImplementedError
    end
  end
end
