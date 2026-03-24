# frozen_string_literal: true

module AgentLoop
  module Effects
    class RunTool < Base
      attr_reader :name, :input, :on_result

      def initialize(name:, input:, on_result: nil)
        @name = name
        @input = input
        @on_result = on_result
      end
    end
  end
end
