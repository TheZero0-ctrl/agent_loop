# frozen_string_literal: true

module AgentLoop
  module Adapters
    module Scheduler
      class Inline
        def schedule(delay_ms:)
          Thread.new do
            sleep(delay_ms.to_f / 1000.0)
            yield
          end

          :ok
        end
      end
    end
  end
end
