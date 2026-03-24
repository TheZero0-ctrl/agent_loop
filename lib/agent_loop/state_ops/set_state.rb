# frozen_string_literal: true

module AgentLoop
  module StateOps
    class SetState < Base
      attr_reader :attrs

      def initialize(attrs:)
        @attrs = attrs
      end
    end
  end
end
