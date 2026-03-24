# frozen_string_literal: true

module AgentLoop
  module Adapters
    class Tool
      def run(_name:, _input:, _instance:, _runtime:)
        raise NotImplementedError
      end
    end
  end
end
