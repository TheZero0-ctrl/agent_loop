# frozen_string_literal: true

require 'json'
require 'logger'

module AgentLoop
  module Adapters
    module Emitter
      class Logger
        def initialize(logger: ::Logger.new($stdout), level: :info)
          @logger = logger
          @level = level
        end

        def emit(signal, target: nil)
          payload = signal.to_h.merge(target: target)
          @logger.public_send(@level, payload.to_json)
          :ok
        end
      end
    end
  end
end
