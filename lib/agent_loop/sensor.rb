# frozen_string_literal: true

require 'dry/schema'

module AgentLoop
  module Sensor
    UNSET = Object.new

    class InvalidConfig < StandardError
      attr_reader :details

      def initialize(message, details: {})
        super(message)
        @details = details
      end
    end

    def self.included(base)
      base.extend(ClassMethods)
      base.include(InstanceMethods)
    end

    module ClassMethods
      def name(value = UNSET)
        return @sensor_name = value unless value.equal?(UNSET)
        return @sensor_name if instance_variable_defined?(:@sensor_name)

        super()
      end

      def description(value = UNSET)
        return @sensor_description = value unless value.equal?(UNSET)

        @sensor_description
      end

      def schema(value = UNSET, &block)
        @config_schema = value unless value.equal?(UNSET)
        @config_schema = Dry::Schema.Params(&block) if block
        @config_schema
      end

      def validate_config!(config)
        input = config || {}
        return input unless @config_schema

        result = @config_schema.call(input)
        return result.to_h if result.success?

        raise AgentLoop::Sensor::InvalidConfig.new('Sensor config validation failed', details: result.errors.to_h)
      end

      def init(config, context: {})
        new.init(config, context: context)
      end

      def handle_event(event, state, context: {})
        new.handle_event(event, state, context: context)
      end

      def terminate(reason, state, context: {})
        new.terminate(reason, state, context: context)
      end
    end

    module InstanceMethods
      def init(config, context: {})
        _config = config
        _context = context
        {}
      end

      def handle_event(_event, _state, context: {})
        _context = context
        raise NotImplementedError, "#{self.class} must implement #handle_event"
      end

      def terminate(reason, state, context: {})
        _reason = reason
        _state = state
        _context = context
        :ok
      end

      def normalize_sensor_result(raw, current_state:, phase:)
        return raw if raw.is_a?(AgentLoop::SensorResult)

        case raw
        when Hash
          AgentLoop::SensorResult.new(state: raw)
        when Array
          normalize_array_result(raw, current_state: current_state, phase: phase)
        else
          AgentLoop::SensorResult.new(state: raw || current_state)
        end
      rescue StandardError => e
        raise AgentLoop::SensorRuntimeError.new(
          "Invalid sensor #{phase} result: #{e.message}",
          code: :invalid_sensor_result,
          context: { sensor_class: self.class.name, phase: phase }
        )
      end

      private

      def normalize_array_result(raw, current_state:, phase:)
        if raw.first == :ok
          normalize_ok_tuple(raw, current_state: current_state)
        elsif raw.first == :error
          normalize_error_tuple(raw, current_state: current_state)
        elsif raw.size == 2
          AgentLoop::SensorResult.new(state: raw[0], effects: raw[1])
        else
          raise ArgumentError, "Unsupported sensor tuple shape for #{phase}"
        end
      end

      def normalize_ok_tuple(raw, current_state:)
        state = raw[1] || current_state
        effects = []
        signals = []

        if raw.size >= 3
          third = raw[2]
          if raw.size == 3
            effects = third
          else
            signals = third
            effects = raw[3]
          end
        end

        AgentLoop::SensorResult.new(state: state, signals: signals, effects: effects)
      end

      def normalize_error_tuple(raw, current_state:)
        reason = raw[1]
        AgentLoop::SensorResult.new(
          state: current_state,
          status: :error,
          error: {
            code: :sensor_callback_error,
            message: reason.to_s,
            reason: reason
          }
        )
      end
    end
  end
end
