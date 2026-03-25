# frozen_string_literal: true

module AgentLoop
  module Adapters
    module Emitter
      class Fanout
        def initialize(adapters:)
          @adapters = adapters
        end

        def emit(signal, target: nil)
          @adapters.map { |adapter| adapter.emit(signal, target: target) }
        end
      end
    end
  end
end
