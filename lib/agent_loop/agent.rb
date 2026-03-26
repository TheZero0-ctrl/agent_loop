# frozen_string_literal: true

require 'dry/schema'

module AgentLoop
  module Agent
    UNSET = Object.new

    class InvalidState < StandardError
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
        return @agent_name = value unless value.equal?(UNSET)
        return @agent_name if instance_variable_defined?(:@agent_name)

        super()
      end

      def description(value = UNSET)
        return @agent_description = value unless value.equal?(UNSET)

        @agent_description
      end

      def schema(value = UNSET, defaults: nil, &block)
        @state_schema = value unless value.equal?(UNSET)
        @state_schema = Dry::Schema.Params(&block) if block
        @schema_defaults = defaults if defaults
        @state_schema
      end

      def schema_defaults
        @schema_defaults || {}
      end

      def default_state(value = nil)
        @default_state = value if value
        @default_state || {}
      end

      def initial_state
        base_state = deep_dup(default_state)
        schema_input = deep_merge(base_state, deep_dup(schema_defaults))
        with_plugins = mount_plugins(schema_input)
        validate_state!(with_plugins)
      end

      def cmd(agent, instruction, context: {})
        raise ArgumentError, "Expected agent to be an instance of #{self}, got #{agent.class}" unless agent.is_a?(self)

        parsed_instructions = parse_instructions(instruction)
        chain_mode = instruction_chain?(instruction)
        evaluator = new
        state_op_applicator = AgentLoop::StateOps::Applicator.new

        current_state = agent.state
        collected_effects = []

        parsed_instructions.each do |entry|
          step_instruction = build_step_instruction(entry, current_state, chain_mode: chain_mode)
          merged_context = build_instruction_context(context, entry)
          result = evaluator.cmd(current_state, step_instruction, context: merged_context)
          current_state = state_op_applicator.apply_all(result.state, result.state_ops)
          collected_effects.concat(result.effects)
        end

        final_state = current_state
        validated_state = validate_state!(final_state)
        [agent.with_state(validated_state), collected_effects]
      rescue AgentLoop::Action::InvalidParams => e
        [
          agent,
          [AgentLoop::Effects::Error.new(code: :invalid_action_params, message: e.message, details: e.details)]
        ]
      rescue AgentLoop::Action::InvalidOutput => e
        [
          agent,
          [AgentLoop::Effects::Error.new(code: :invalid_action_output, message: e.message, details: e.details)]
        ]
      rescue AgentLoop::Agent::InvalidState => e
        [
          agent,
          [AgentLoop::Effects::Error.new(code: :invalid_state, message: e.message, details: e.details)]
        ]
      end

      def route(signal_type, to:, priority: 0)
        routes[signal_type] = { target: to, priority: priority }
      end

      def routes
        @routes ||= {}
      end

      def plugin_signal_route(signal_type, to:, priority: -10)
        plugin_routes[signal_type] = { target: to, priority: priority }
      end

      def plugin_routes
        @plugin_routes ||= {}
      end

      def plugin(plugin_module, state_key: nil)
        plugins << { module: plugin_module, state_key: state_key }
      end

      def plugins
        @plugins ||= []
      end

      def signal_routes(_context = {})
        routes.map do |pattern, target_spec|
          if target_spec.is_a?(Hash) && target_spec.key?(:target)
            [pattern, target_spec.fetch(:target), target_spec.fetch(:priority, 0)]
          else
            [pattern, target_spec, 0]
          end
        end
      end

      def plugin_signal_routes(_context = {})
        static_routes = plugin_routes.map do |pattern, target_spec|
          if target_spec.is_a?(Hash) && target_spec.key?(:target)
            [pattern, target_spec.fetch(:target), target_spec.fetch(:priority, -10)]
          else
            [pattern, target_spec, -10]
          end
        end

        dynamic_routes = plugins.flat_map do |plugin_entry|
          plugin_module = plugin_entry.fetch(:module)
          next [] unless plugin_module.respond_to?(:signal_routes)

          route_context = { plugin: plugin_module, state_key: plugin_entry[:state_key] }
          invoke_route_provider(plugin_module, route_context)
        end

        static_routes + dynamic_routes
      end

      def transform_result_with_plugins(result, instruction:, context: {})
        plugins.reduce(result) do |current, plugin_entry|
          plugin_module = plugin_entry.fetch(:module)
          next current unless plugin_module.respond_to?(:transform_result)

          plugin_context = context.merge(plugin: plugin_module, state_key: plugin_entry[:state_key])
          transformed = invoke_plugin_hook(plugin_module, :transform_result,
                                           result: current,
                                           instruction: instruction,
                                           context: plugin_context)
          transformed.is_a?(AgentLoop::Result) ? transformed : current
        end
      end

      def handle_signal_with_plugins(signal, context: {})
        plugins.reduce(signal) do |current_signal, plugin_entry|
          plugin_module = plugin_entry.fetch(:module)
          next current_signal unless plugin_module.respond_to?(:handle_signal)

          plugin_context = context.merge(plugin: plugin_module, state_key: plugin_entry[:state_key])
          transformed = invoke_plugin_hook(plugin_module, :handle_signal,
                                           signal: current_signal,
                                           context: plugin_context)
          transformed.is_a?(AgentLoop::Signal) ? transformed : current_signal
        end
      end

      def on_before_cmd(agent:, instruction:, context:)
        _agent = agent
        [instruction, context]
      end

      def on_after_cmd(agent:, instruction:, result:, context:)
        _agent = agent
        _instruction = instruction
        _context = context
        result
      end

      def on_cmd_error(agent:, instruction:, error:, context:)
        _agent = agent
        _instruction = instruction
        _context = context
        raise error
      end

      private

      def mount_plugins(state)
        plugins.reduce(deep_dup(state)) do |current_state, plugin_entry|
          plugin_module = plugin_entry.fetch(:module)
          state_key = plugin_entry[:state_key]

          mounted = if plugin_module.respond_to?(:mount)
                      invoke_plugin_hook(plugin_module, :mount,
                                         state: current_state,
                                         agent_class: self,
                                         state_key: state_key)
                    else
                      current_state
                    end

          next_state = mounted.is_a?(Hash) ? mounted : current_state
          next next_state unless state_key

          with_key = deep_dup(next_state)
          with_key[state_key] = {} unless with_key.key?(state_key)
          with_key
        end
      end

      def parse_instructions(instruction)
        AgentLoop::Instruction.normalize(instruction)
      end

      def instruction_chain?(instruction)
        instruction.is_a?(Array) && !AgentLoop::Instruction.tuple_instruction?(instruction)
      end

      def build_step_instruction(instruction, current_state, chain_mode:)
        return instruction unless chain_mode

        merged_params = deep_merge(current_state, instruction.params || {})
        instruction.with(params: merged_params)
      end

      def build_instruction_context(base_context, instruction)
        merged = base_context.merge(instruction.context || {})
        return merged if instruction.opts.nil? || instruction.opts == {} || instruction.opts == []

        merged.merge(opts: instruction.opts)
      end

      def validate_state!(state)
        input = deep_dup(state)
        return input unless @state_schema

        result = @state_schema.call(input)
        return deep_merge(input, result.to_h) if result.success?

        raise AgentLoop::Agent::InvalidState.new('State schema validation failed', details: result.errors.to_h)
      end

      def invoke_route_provider(provider, context)
        method = provider.method(:signal_routes)
        if method.arity.zero?
          method.call
        else
          method.call(context)
        end
      rescue ArgumentError
        []
      end

      def invoke_plugin_hook(plugin_module, hook_name, payload)
        method = plugin_module.method(hook_name)
        if method.arity == 1
          method.call(payload)
        else
          method.call(**payload)
        end
      rescue ArgumentError
        method.call(payload)
      end

      def deep_dup(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(key, value), memo| memo[key] = deep_dup(value) }
        when Array
          obj.map { |value| deep_dup(value) }
        else
          obj
        end
      end

      def deep_merge(left, right)
        return deep_dup(right) unless left.is_a?(Hash) && right.is_a?(Hash)

        left.each_with_object(deep_dup(right)) do |(key, value), memo|
          memo[key] = if memo.key?(key)
                        deep_merge(value, memo[key])
                      else
                        deep_dup(value)
                      end
        end
      end
    end

    module InstanceMethods
      attr_reader :state, :metadata

      def initialize(state: nil, metadata: {})
        @state = deep_dup(state.nil? ? self.class.initial_state : state)
        @metadata = deep_dup(metadata)
      end

      def with_state(state)
        self.class.new(state: state, metadata: metadata)
      end

      def with(state: self.state, metadata: self.metadata)
        self.class.new(state: state, metadata: metadata)
      end
    end

    def initial_state
      self.class.initial_state
    end

    def cmd(state, instruction, context: {})
      prepared_instruction, prepared_context = self.class.on_before_cmd(
        agent: self,
        instruction: instruction,
        context: context
      )

      output = execute_instruction(state, prepared_instruction, context: prepared_context)
      result = normalize_cmd_output(output)

      self.class.on_after_cmd(
        agent: self,
        instruction: prepared_instruction,
        result: result,
        context: prepared_context
      )
    rescue StandardError => e
      handled = self.class.on_cmd_error(
        agent: self,
        instruction: instruction,
        error: e,
        context: context
      )

      handled.is_a?(Result) ? handled : raise(e)
    end

    private

    def execute_instruction(state, instruction, context: {})
      if action_class?(instruction.action)
        instruction.action.call(params: instruction.params, state: state, context: context)
      else
        raise NoMethodError, "Undefined action method: #{instruction.action}" unless respond_to?(instruction.action)

        public_send(instruction.action, normalize_method_params(instruction.params), state: state, context: context)
      end
    end

    def action_class?(action)
      action.is_a?(Class) && action <= AgentLoop::Action
    end

    def partition_operations(operations)
      Array(operations).partition { |operation| operation.is_a?(AgentLoop::StateOps::Base) }
    end

    def normalize_cmd_output(output)
      return output if output.is_a?(Result)

      new_state, operations = output
      state_ops, effects = partition_operations(operations)
      Result.new(state: new_state, state_ops: state_ops, effects: effects)
    end

    def normalize_method_params(params)
      deep_indifferent_keys(params || {})
    end

    def deep_indifferent_keys(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(key, value), memo|
          normalized_value = deep_indifferent_keys(value)
          memo[key] = normalized_value
          if key.is_a?(String)
            memo[key.to_sym] = normalized_value
          elsif key.is_a?(Symbol)
            memo[key.to_s] = normalized_value
          end
        end
      when Array
        obj.map { |value| deep_indifferent_keys(value) }
      else
        obj
      end
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
