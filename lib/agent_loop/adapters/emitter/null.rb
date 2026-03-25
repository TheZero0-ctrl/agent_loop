# frozen_string_literal: true

module AgentLoop
  module Adapters
    module Emitter
      class Null
        def emit(_signal, target: nil)
          :ok
        end
      end
    end
  end
end
