# frozen_string_literal: true

module AgentLoop
  module StateOps
    class ReplaceState < Base
      attr_reader :state

      def initialize(state:)
        @state = state
      end
    end
  end
end
