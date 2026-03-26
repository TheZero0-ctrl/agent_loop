# frozen_string_literal: true

module AgentLoop
  class AgentServer
    attr_reader :runtime, :instance

    def initialize(runtime:, instance:)
      @runtime = runtime
      @instance = instance
    end

    def call(signal, context: {})
      runtime.call(instance, signal, context: context)
    end

    def cast(signal, context: {})
      runtime.cast(instance, signal, context: context)
    end

    def drain(limit: nil)
      runtime.drain(limit: limit)
    end

    def tick(context: {})
      runtime.tick(instance, context: context)
    end

    def snapshot
      {
        runtime: runtime.snapshot(instance),
        instance: {
          id: instance.id,
          status: instance.status,
          state: instance.state,
          state_version: instance.metadata[:state_version],
          last_error: instance.metadata[:last_error],
          children: instance.children.keys
        }
      }
    end
  end
end
