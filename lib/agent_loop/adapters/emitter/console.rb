# frozen_string_literal: true

require "json"

module AgentLoop
  module Adapters
    module Emitter
      class Console
        def initialize(io: $stdout)
          @io = io
        end

        def emit(signal, target: nil)
          payload = signal.to_h.merge(target: target)
          @io.puts(payload.to_json)
          :ok
        end
      end
    end
  end
end
