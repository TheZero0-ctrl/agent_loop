# frozen_string_literal: true

module AgentLoop
  module AI
    class ToolExecSink
      def enqueue(_request)
        raise NotImplementedError
      end

      def dequeue(instance_id:, limit: nil)
        raise NotImplementedError
      end

      def size(instance_id: nil)
        raise NotImplementedError
      end
    end
  end
end
