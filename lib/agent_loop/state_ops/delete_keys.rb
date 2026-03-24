# frozen_string_literal: true

module AgentLoop
  module StateOps
    class DeleteKeys < Base
      attr_reader :keys

      def initialize(keys:)
        @keys = Array(keys)
      end
    end
  end
end
