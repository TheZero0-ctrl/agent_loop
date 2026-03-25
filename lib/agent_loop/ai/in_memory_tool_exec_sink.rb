# frozen_string_literal: true

module AgentLoop
  module AI
    class InMemoryToolExecSink < ToolExecSink
      def initialize
        @mutex = Mutex.new
        @requests = []
      end

      def enqueue(request)
        @mutex.synchronize do
          @requests << request
        end
        request
      end

      def dequeue(instance_id:, limit: nil)
        @mutex.synchronize do
          selected = if instance_id
                       @requests.select { |request| request.instance_id == instance_id }
                     else
                       @requests.dup
                     end
          selected = selected.first(limit) if limit

          request_ids = selected.map(&:id)
          @requests.reject! { |request| request_ids.include?(request.id) }
          selected
        end
      end

      def peek(instance_id: nil)
        @mutex.synchronize do
          return @requests.select { |request| request.instance_id == instance_id } if instance_id

          @requests.dup
        end
      end

      def size(instance_id: nil)
        @mutex.synchronize do
          return @requests.count { |request| request.instance_id == instance_id } if instance_id

          @requests.size
        end
      end

      def clear
        @mutex.synchronize do
          @requests.clear
        end
      end
    end
  end
end
