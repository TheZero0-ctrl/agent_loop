# frozen_string_literal: true

module AgentLoop
  module Adapters
    module Scheduler
      class Inline
        def schedule(delay_ms:, &block)
          Thread.new do
            sleep(delay_ms.to_f / 1000.0)
            block.call
          end

          :ok
        end
      end
    end
  end
end
