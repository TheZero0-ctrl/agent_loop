# frozen_string_literal: true

require 'test_helper'

module Adapters
  module Tools
    class AgentStrategyRegistryTest < Minitest::Test
      class LookupCustomerAction < AgentLoop::Action
        name 'lookup_customer'

        schema do
          required(:email).filled(:string)
        end

        def self.run(params, _context)
          { found: true, email: params.fetch(:email) }
        end
      end

      class ReactToolAgent
        include AgentLoop::Agent

        strategy AgentLoop::Strategies::React,
                 tools: [LookupCustomerAction]
      end

      class PlainAgent
        include AgentLoop::Agent
      end

      def test_resolves_tools_from_agent_strategy_configuration
        adapter = AgentLoop::Adapters::Tools::AgentStrategyRegistry.new
        runtime = AgentLoop::Runtime.new(
          effect_executor: AgentLoop::Effects::Executor.new(emit_adapter: AgentLoop::Adapters::Emitter::Null.new)
        )
        instance = AgentLoop::Instance.new(agent_class: ReactToolAgent, id: 'tool-resolve-1', state: {})

        output = adapter.run(
          name: 'lookup_customer',
          input: { email: 'jane@example.com' },
          instance: instance,
          runtime: runtime,
          meta: {}
        )

        assert(output[:ok])
        assert(output.dig(:output_patch, :found))
      end

      def test_falls_back_when_agent_has_no_react_tools
        fallback = AgentLoop::Adapters::Tools::Null.new
        adapter = AgentLoop::Adapters::Tools::AgentStrategyRegistry.new(fallback: fallback)
        runtime = AgentLoop::Runtime.new(
          effect_executor: AgentLoop::Effects::Executor.new(emit_adapter: AgentLoop::Adapters::Emitter::Null.new)
        )
        instance = AgentLoop::Instance.new(agent_class: PlainAgent, id: 'tool-resolve-2', state: {})

        output = adapter.run(
          name: 'lookup_customer',
          input: { email: 'jane@example.com' },
          instance: instance,
          runtime: runtime,
          meta: {}
        )

        assert_equal AgentLoop::Adapters::Tools::Null.name, output[:adapter]
        assert_equal 'lookup_customer', output[:tool]
      end
    end
  end
end
