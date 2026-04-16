# frozen_string_literal: true

module AgentLoop
  module Adapters
    module Tools
      class AgentStrategyRegistry < AgentLoop::Adapters::Tool
        def initialize(fallback: AgentLoop::Adapters::Tools::Null.new)
          @fallback = fallback
        end

        def run(name:, input:, instance:, runtime:, meta: {})
          registry = registry_for(instance: instance, runtime: runtime)
          unless registry
            return @fallback.run(name: name, input: input, instance: instance, runtime: runtime,
                                 meta: meta)
          end

          registry.run(name: name, input: input, instance: instance, runtime: runtime, meta: meta)
        end

        private

        def registry_for(instance:, runtime:)
          actions = resolve_actions(instance: instance, runtime: runtime)
          return nil if actions.empty?

          AgentLoop::Adapters::Tools::ActionRegistry.new(actions: actions)
        end

        def resolve_actions(instance:, runtime:)
          class_actions = strategy_tools_from_options(instance.agent_class)
          return class_actions unless class_actions.empty?

          strategy = runtime.strategy_for(instance.agent_class)
          strategy_actions = strategy.respond_to?(:tool_actions) ? Array(strategy.tool_actions) : []
          filter_action_classes(strategy_actions)
        end

        def strategy_tools_from_options(agent_class)
          return [] unless agent_class.respond_to?(:strategy_opts)

          opts = agent_class.strategy_opts
          tools = opts[:tools] || opts['tools']
          filter_action_classes(Array(tools))
        end

        def filter_action_classes(candidates)
          candidates.select { |candidate| candidate.is_a?(Class) && candidate <= AgentLoop::Action }
        end
      end
    end
  end
end
