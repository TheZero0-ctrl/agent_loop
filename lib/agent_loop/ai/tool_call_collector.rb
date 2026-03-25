# frozen_string_literal: true

module AgentLoop
  module AI
    class ToolCallCollector < InMemoryToolExecSink
      def drain(instance_id: nil, limit: nil)
        dequeue(instance_id: instance_id, limit: limit)
      end

      def empty?(instance_id: nil)
        size(instance_id: instance_id).zero?
      end

      def to_a
        peek
      end
    end
  end
end
