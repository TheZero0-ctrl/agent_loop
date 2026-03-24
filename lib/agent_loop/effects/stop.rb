# frozen_string_literal: true

module AgentLoop
  module Effects
    class Stop < Base
      attr_reader :reason

      def initialize(reason: :normal)
        @reason = reason
      end
    end
  end
end
