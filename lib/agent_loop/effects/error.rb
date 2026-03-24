# frozen_string_literal: true

module AgentLoop
  module Effects
    class Error < Base
      attr_reader :code, :message, :details

      def initialize(code:, message:, details: {})
        @code = code
        @message = message
        @details = details
      end
    end
  end
end
