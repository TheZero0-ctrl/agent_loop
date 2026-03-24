# frozen_string_literal: true

require_relative "../event_store"

module AgentLoop
  module EventStores
    class InMemory < EventStore
      def initialize
        @events = Hash.new { |hash, key| hash[key] = [] }
      end

      def append(instance_id, event)
        record = event.merge(seq: next_seq(instance_id), recorded_at: Time.now.utc)
        @events[instance_id] << record
        record
      end

      def read(instance_id, from: nil)
        events = @events.fetch(instance_id, [])
        return events.dup unless from

        events.select { |event| event[:seq] >= from }
      end

      private

      def next_seq(instance_id)
        @events[instance_id].size + 1
      end
    end
  end
end
