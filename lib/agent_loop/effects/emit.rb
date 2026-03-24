# frozen_string_literal: true

module AgentLoop
  module Effects
    class Emit < Base
      attr_reader :type, :data, :target

      def initialize(type:, data: {}, target: nil)
        @type = type
        @data = data
        @target = target
      end
    end
  end
end
