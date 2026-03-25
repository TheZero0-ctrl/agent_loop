# frozen_string_literal: true

require_relative "../tool"

module AgentLoop
  module Adapters
    module Tools
      class ActionRegistry < AgentLoop::Adapters::Tool
        class ActionNotFound < StandardError; end
        class ToolActionEffectsNotSupported < StandardError; end

        def initialize(actions:)
          @actions = Array(actions).each_with_object({}) do |action, memo|
            memo[action.name.to_s] = action
          end
        end

        def run(name:, input:, instance:, runtime:, meta: {})
          action = @actions[name.to_s]
          raise ActionNotFound, "No action registered for tool: #{name}" unless action

          previous_state = instance.state || runtime.state_store.load(instance.id) || {}

          result = action.call(
            params: input,
            state: previous_state,
            context: {
              instance_id: instance.id,
              runtime: runtime.class.name,
              trace_id: meta[:trace_id],
              correlation_id: meta[:correlation_id],
              causation_id: meta[:causation_id],
              tool_call_id: meta[:tool_call_id]
            }
          )

          if result.effects.any?
            raise ToolActionEffectsNotSupported,
                  "Tool-backed actions must return state output only. Got effects: #{result.effects.map(&:class).join(", ")}"
          end

          output_patch = deep_diff(previous_state, result.state)

          {
            ok: true,
            action: action.name.to_s,
            tool_call_id: meta[:tool_call_id],
            output_patch: output_patch,
            state: result.state,
            status: result.status
          }
        end

        private

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
