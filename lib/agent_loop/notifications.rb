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
    end
  end
end
