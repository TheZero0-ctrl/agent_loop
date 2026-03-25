# frozen_string_literal: true

require "test_helper"

class RouterTest < Minitest::Test
  class StrategyAction < AgentLoop::Action
    def self.run(_params, _context)
      {}
    end
  end

  class AgentAction < AgentLoop::Action
    def self.run(_params, _context)
      {}
    end
  end

  class WildcardAction < AgentLoop::Action
    def self.run(_params, _context)
      {}
    end
  end

  class StrategyWithRoutes < AgentLoop::Strategies::Base
    def cmd(agent:, state:, instruction:, context:)
      agent.cmd(state, instruction, context: context)
    end

    def signal_routes(_context = {})
      [["support.ticket.created", StrategyAction]]
    end
  end

  class AgentWithRoutes
    include AgentLoop::Agent

    route "support.ticket.created", to: AgentAction
  end

  class AgentWithWildcards
    include AgentLoop::Agent

    route "support.*", to: AgentAction
    route "support.**", to: WildcardAction
  end

  class AgentWithPluginRoute
    include AgentLoop::Agent

    route "support.ticket.created", to: AgentAction
    plugin_signal_route "support.ticket.created", to: WildcardAction
  end

  def test_strategy_route_has_priority_over_agent_route
    router = AgentLoop::Router.new
    signal = AgentLoop::Signal.new(type: "support.ticket.created", source: "test")

    instruction = router.instruction_for(AgentWithRoutes, signal, strategy: StrategyWithRoutes.new)

    assert_equal StrategyAction, instruction.action
    assert_equal :strategy, instruction.meta[:route_source]
    assert_equal 50, instruction.meta[:route_priority]
  end

  def test_exact_route_wins_over_multi_wildcard
    router = AgentLoop::Router.new
    signal = AgentLoop::Signal.new(type: "support.ticket", source: "test")

    instruction = router.instruction_for(AgentWithWildcards, signal)

    assert_equal AgentAction, instruction.action
    assert_equal "support.*", instruction.meta[:route_pattern]
  end

  def test_multi_wildcard_matches_deep_paths
    router = AgentLoop::Router.new
    signal = AgentLoop::Signal.new(type: "support.ticket.high.priority", source: "test")

    instruction = router.instruction_for(AgentWithWildcards, signal)

    assert_equal WildcardAction, instruction.action
    assert_equal "support.**", instruction.meta[:route_pattern]
  end

  def test_raises_when_no_route_matches
    router = AgentLoop::Router.new
    signal = AgentLoop::Signal.new(type: "missing.route", source: "test")

    error = assert_raises(AgentLoop::Router::RouteNotFound) do
      router.instruction_for(AgentWithRoutes, signal)
    end

    assert_match "missing.route", error.message
  end

  def test_agent_route_has_priority_over_plugin_route
    router = AgentLoop::Router.new
    signal = AgentLoop::Signal.new(type: "support.ticket.created", source: "test")

    instruction = router.instruction_for(AgentWithPluginRoute, signal)

    assert_equal AgentAction, instruction.action
    assert_equal :agent, instruction.meta[:route_source]
  end
end
