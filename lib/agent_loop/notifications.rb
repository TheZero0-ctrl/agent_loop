# frozen_string_literal: true

module AgentLoop
  module Notifications
    class << self
      def instrument(event_name, payload = {})
        if defined?(ActiveSupport::Notifications)
          ActiveSupport::Notifications.instrument(event_name, payload) { yield if block_given? }
        elsif block_given?
          yield
        end
      end

      def instrument_lifecycle(base_event, payload = {})
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        instrument("#{base_event}.start", payload)

        result = yield

        duration_ms = elapsed_ms(start_time)
        instrument("#{base_event}.stop", payload.merge(duration_ms: duration_ms))
        result
      rescue StandardError => e
        duration_ms = elapsed_ms(start_time)
        instrument("#{base_event}.error", payload.merge(duration_ms: duration_ms, error_class: e.class.name,
                                                        error_message: e.message))
        raise
      end

      private

      def elapsed_ms(start_time)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0).round(3)
      end
    end
  end
end
