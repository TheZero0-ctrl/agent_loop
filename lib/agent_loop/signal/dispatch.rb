# frozen_string_literal: true

module AgentLoop
  class Signal
    module Dispatch
      module_function

      def dispatch(signal, config)
        Array(config).map do |entry|
          adapter, options = normalize_entry(entry)
          adapter.emit(signal, **options)
        end
      end

      def adapter(type, options = {})
        case type
        when :noop
          AgentLoop::Adapters::Emitter::Null.new
        when :console
          AgentLoop::Adapters::Emitter::Console.new(**options)
        when :logger
          AgentLoop::Adapters::Emitter::Logger.new(**options)
        when :http
          AgentLoop::Adapters::Emitter::Http.new(**options)
        when :webhook
          AgentLoop::Adapters::Emitter::Webhook.new(**options)
        when :pubsub
          AgentLoop::Adapters::Emitter::Pubsub.new(**options)
        else
          raise ArgumentError, "Unknown signal dispatch adapter: #{type.inspect}"
        end
      end

      def normalize_entry(entry)
        if entry.is_a?(Array) && entry.size == 2
          options = entry[1].dup
          target = options.delete(:target)
          [adapter(entry[0], options), { target: target }]
        elsif entry.is_a?(Hash)
          type = entry.fetch(:adapter)
          options = entry.reject { |key, _| key == :adapter }.dup
          target = options.delete(:target)
          [adapter(type, options), { target: target }]
        else
          raise ArgumentError, "Invalid dispatch config: #{entry.inspect}"
        end
      end
      private_class_method :normalize_entry
    end
  end
end
