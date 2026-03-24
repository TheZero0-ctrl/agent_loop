# frozen_string_literal: true

module AgentLoop
  module Effects
    class RunTool < Base
      attr_reader :name, :input, :callback_event

      def initialize(name:, input:, callback_event: nil, on_result: nil)
        @name = name
        @input = input
        @callback_event = callback_event || on_result
      end
    end
  end
end
