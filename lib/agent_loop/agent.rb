# frozen_string_literal: true

module AgentLoop
  module Agent
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def default_state(value = nil)
        @default_state = value if value
        @default_state || {}
      end

      def route(signal_type, to:)
        routes[signal_type] = to
      end

      def routes
        @routes ||= {}
      end
    end

    def initial_state
      deep_dup(self.class.default_state)
    end

    def cmd(state, instruction, context: {})
      raise NoMethodError, "Undefined action method: #{instruction.action}" unless respond_to?(instruction.action)

      output = public_send(instruction.action, instruction.params, state: state, context: context)

      if output.is_a?(Result)
        output
      else
        new_state, operations = output
        state_ops, effects = partition_operations(operations)
        Result.new(state: new_state, state_ops: state_ops, effects: effects)
      end
    end

    private

    def partition_operations(operations)
      Array(operations).partition { |operation| operation.is_a?(AgentLoop::StateOps::Base) }
    end

    def deep_dup(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), memo| memo[k] = deep_dup(v) }
      when Array
        obj.map { |v| deep_dup(v) }
      else
        obj
      end
    end
  end
end
