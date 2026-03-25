# frozen_string_literal: true

module AgentLoop
  module AI
    class ToolExecDispatcher
      def initialize(sink: InMemoryToolExecSink.new)
        @sink = sink
      end

      def dispatch(instance:, runtime:, limit: nil)
        AgentLoop::Notifications.instrument('agent_loop.tool.dispatch', instance_id: instance.id) do
          ToolAdapter.run_deferred!(sink: @sink, runtime: runtime, instance: instance, limit: limit)
        end
      end
    end
  end
end
