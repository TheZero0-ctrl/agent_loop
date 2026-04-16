# frozen_string_literal: true

require_relative '../tool'

module AgentLoop
  module Adapters
    module Tools
      class ActionRegistry < AgentLoop::Adapters::Tool
        class ActionNotFound < StandardError; end
        class DuplicateToolName < StandardError; end
        class InvalidToolDescriptor < StandardError; end
        class ToolActionEffectsNotSupported < StandardError; end

        class ToolExecutionFailed < StandardError
          attr_reader :tool_name, :details

          def initialize(tool_name:, message:, details: {})
            super(message)
            @tool_name = tool_name
            @details = details
          end
        end

        def initialize(actions:, strict: nil, expose_instance_state: false)
          @strict = strict
          @expose_instance_state = expose_instance_state
          @actions = build_registry(Array(actions))
        end

        def run(name:, input:, instance:, runtime:, meta: {})
          tool_name = name.to_s
          action = @actions[tool_name]
          raise ActionNotFound, "No action registered for tool: #{tool_name}" unless action

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          previous_state = initial_tool_state(instance: instance, runtime: runtime)
          execution_context = build_execution_context(instance: instance, runtime: runtime, meta: meta)

          result = action.call(params: input, state: previous_state, context: execution_context)
          raise_on_effects!(result, tool_name)

          duration_ms = elapsed_ms(started_at)
          output_patch = deep_diff(previous_state, result.state)

          {
            ok: true,
            action: action.name.to_s,
            action_class: action.to_s,
            action_ref: meta[:action_ref],
            tool: tool_name,
            tool_call_id: meta[:tool_call_id],
            output_patch: output_patch,
            state: result.state,
            status: result.status,
            duration_ms: duration_ms
          }
        rescue AgentLoop::Action::InvalidParams, AgentLoop::Action::InvalidOutput => e
          raise ToolExecutionFailed.new(
            tool_name: tool_name,
            message: "Tool action validation failed for #{tool_name}: #{e.message}",
            details: e.respond_to?(:details) ? e.details : {}
          )
        rescue ToolActionEffectsNotSupported
          raise
        rescue StandardError => e
          raise ToolExecutionFailed.new(
            tool_name: tool_name,
            message: "Tool action execution failed for #{tool_name}: #{e.message}",
            details: { error_class: e.class.name }
          )
        end

        private

        attr_reader :strict

        def build_registry(actions)
          actions.each_with_object({}) do |action, memo|
            validate_action_class!(action)
            descriptor = action.to_tool(strict: strict_mode_for?(action))
            tool_name = extract_tool_name(descriptor)

            if memo.key?(tool_name)
              raise DuplicateToolName,
                    "Duplicate tool name '#{tool_name}' registered for #{memo[tool_name]} and #{action}"
            end

            validate_descriptor!(tool_name, descriptor, action)
            memo[tool_name] = action
          end
        end

        def validate_action_class!(action)
          return if action.respond_to?(:call) && action.respond_to?(:to_tool)

          raise InvalidToolDescriptor,
                "Tool action must respond to .call and .to_tool, got: #{action.inspect}"
        end

        def extract_tool_name(descriptor)
          name = descriptor[:name] || descriptor['name']
          name = name.to_s
          raise InvalidToolDescriptor, 'Tool descriptor name cannot be blank' if name.empty?

          name
        end

        def validate_descriptor!(tool_name, descriptor, action)
          parameters = descriptor[:parameters] || descriptor['parameters']
          return if parameters.is_a?(Hash)

          raise InvalidToolDescriptor,
                "Tool '#{tool_name}' from #{action} must expose hash parameters schema"
        end

        def strict_mode_for?(action)
          return action.strict? if strict.nil?

          strict == true
        end

        def initial_tool_state(instance:, runtime:)
          return runtime.state_store.load(instance.id) || instance.state || {} if @expose_instance_state

          {}
        end

        def build_execution_context(instance:, runtime:, meta:)
          {
            instance_id: instance.id,
            runtime: runtime.class.name,
            trace_id: meta[:trace_id],
            correlation_id: meta[:correlation_id],
            causation_id: meta[:causation_id],
            tool_call_id: meta[:tool_call_id]
          }.compact
        end

        def raise_on_effects!(result, tool_name)
          return unless result.effects.any?

          effect_names = result.effects.map(&:class).join(', ')
          raise ToolActionEffectsNotSupported,
                "Tool-backed action '#{tool_name}' must return state output only. Got effects: #{effect_names}"
        end

        def elapsed_ms(started_at)
          finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ((finished_at - started_at) * 1000.0).round(3)
        end

        def deep_diff(before, after)
          before = {} unless before.is_a?(Hash)
          after = {} unless after.is_a?(Hash)

          after.each_with_object({}) do |(key, value), memo|
            previous_value = before[key]

            memo[key] = if value.is_a?(Hash) && previous_value.is_a?(Hash)
                          nested = deep_diff(previous_value, value)
                          nested unless nested.empty?
                        elsif previous_value != value
                          value
                        end
          end.compact
        end
      end
    end
  end
end
