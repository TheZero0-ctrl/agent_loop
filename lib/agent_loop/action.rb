# frozen_string_literal: true

require "dry/schema"

module AgentLoop
  class Action
    UNSET = Object.new

    class InvalidParams < StandardError
      attr_reader :details

      def initialize(message, details: {})
        super(message)
        @details = details
      end
    end

    class InvalidOutput < StandardError
      attr_reader :details

      def initialize(message, details: {})
        super(message)
        @details = details
      end
    end

    class << self
      def name(value = UNSET)
        return @action_name = value unless value.equal?(UNSET)
        return @action_name if instance_variable_defined?(:@action_name)

        super()
      end

      def description(value = UNSET)
        return @action_description = value unless value.equal?(UNSET)

        @action_description
      end

      def schema(value = UNSET, defaults: nil, &block)
        @params_schema = value unless value.equal?(UNSET)
        @params_schema = Dry::Schema.Params(&block) if block
        @schema_defaults = defaults if defaults
        @params_schema
      end

      def schema_defaults
        @schema_defaults || {}
      end

      def param_descriptions(value = UNSET)
        return @param_descriptions = value unless value.equal?(UNSET)

        @param_descriptions || {}
      end

      def output_schema(value = UNSET, defaults: nil, &block)
        @output_schema = value unless value.equal?(UNSET)
        @output_schema = Dry::Schema.Params(&block) if block
        @output_schema_defaults = defaults if defaults
        @output_schema
      end

      def output_schema_defaults
        @output_schema_defaults || {}
      end

      def strict(value = UNSET)
        return @strict = value unless value.equal?(UNSET)

        @strict == true
      end

      def strict?
        strict
      end

      def parameters_json_schema(strict: nil)
        return nil unless @params_schema

        strict_mode = strict.nil? ? strict? : strict
        AgentLoop::Action::Schema.to_json_schema(
          schema: @params_schema,
          defaults: schema_defaults,
          descriptions: param_descriptions,
          strict: strict_mode
        )
      end

      def to_tool(strict: nil)
        {
          name: name.to_s,
          description: description,
          parameters: parameters_json_schema(strict: strict)
        }
      end

      def call(params:, state:, context: {})
        validated_params = validate_params!(params)
        action_context = context.merge(state: state)
        output = run(validated_params, action_context)
        normalize_output(state, output)
      end

      def run(_params, _context)
        raise NotImplementedError
      end

      private

      def validate_params!(params)
        normalized_params = deep_symbolize_keys(params || {})
        input = schema_defaults.merge(normalized_params)
        return input unless @params_schema

        result = @params_schema.call(input)
        return deep_merge(input, result.to_h) if result.success?

        raise InvalidParams.new("Action params validation failed", details: result.errors.to_h)
      end

      def validate_output!(output)
        normalized_output = deep_symbolize_keys(output || {})
        input = output_schema_defaults.merge(normalized_output)
        return input unless @output_schema

        result = @output_schema.call(input)
        return deep_merge(input, result.to_h) if result.success?

        raise InvalidOutput.new("Action output validation failed", details: result.errors.to_h)
      end

      def normalize_output(previous_state, output)
        return output if output.is_a?(AgentLoop::Result)

        next_state, effects = if output.is_a?(Array)
                                [output[0], output[1]]
                              else
                                [output, []]
                              end

        validated_output = validate_output!(next_state || {})
        state = deep_merge(previous_state, validated_output)
        AgentLoop::Result.new(state: state, effects: effects)
      end

      def deep_symbolize_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(key, value), memo|
            memo[symbolize_key(key)] = deep_symbolize_keys(value)
          end
        when Array
          obj.map { |value| deep_symbolize_keys(value) }
        else
          obj
        end
      end

      def symbolize_key(key)
        key.is_a?(String) ? key.to_sym : key
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
  end
end
