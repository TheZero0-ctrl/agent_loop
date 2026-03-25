# frozen_string_literal: true

module AgentLoop
  module Adapters
    module Emitter
      class Pubsub
        def initialize(topic:, publisher:)
          @topic = topic
          @publisher = publisher
        end

        def emit(signal, target: nil)
          topic = target || @topic
          message = signal.to_h

          if @publisher.respond_to?(:publish)
            @publisher.publish(topic, message)
          else
            @publisher.call(topic: topic, message: message)
          end

          :ok
        end
      end
    end
  end
end
