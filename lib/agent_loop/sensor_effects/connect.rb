# frozen_string_literal: true

module AgentLoop
  module SensorEffects
    class Connect < Base
      attr_reader :adapter, :opts

      def initialize(adapter:, opts: {})
        @adapter = adapter
        @opts = opts || {}
      end
    end
  end
end
