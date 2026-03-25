# frozen_string_literal: true

module AgentLoop
  module Adapters
    module Emitter
      class Null
        def emit(_signal, target: nil)
          _target = target
          :ok
        end
      end
    end
  end
end
