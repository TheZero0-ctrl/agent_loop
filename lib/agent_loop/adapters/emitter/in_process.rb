# frozen_string_literal: true

module AgentLoop
  module Adapters
    module Emitter
      class InProcess
        attr_reader :events

        def initialize
          @events = []
        end

        def emit(signal, target: nil)
          @events << { signal: signal, target: target }
          :ok
        end
      end
    end
  end
end
