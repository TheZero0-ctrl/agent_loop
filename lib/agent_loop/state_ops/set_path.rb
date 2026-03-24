# frozen_string_literal: true

module AgentLoop
  module StateOps
    class SetPath < Base
      attr_reader :path, :value

      def initialize(path:, value:)
        @path = Array(path)
        @value = value
      end
    end
  end
end
