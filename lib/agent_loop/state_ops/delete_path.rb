# frozen_string_literal: true

module AgentLoop
  module StateOps
    class DeletePath < Base
      attr_reader :path

      def initialize(path:)
        @path = Array(path)
      end
    end
  end
end
