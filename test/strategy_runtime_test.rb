# frozen_string_literal: true

require 'test_helper'

class StrategyRuntimeParityTest < Minitest::Test
  class IncrementAction < AgentLoop::Action
    schema defaults: { by: 1 } do
      required(:by).filled(:integer)
    end

    def self.run(params, context)
      { count: context.fetch(:state).fetch(:count, 0) + params.fetch(:by) }
    end
  end

  class InitTrackingStrategy < AgentLoop::Strategies::Base
    class << self
      attr_accessor :init_calls
    end

    self.init_calls = 0

    def self.reset!
      self.init_calls = 0
    end

    def init(instance:, runtime:, context: {})
      _runtime = runtime
      _context = context
      self.class.init_calls += 1

      AgentLoop::Result.new(
        state: instance.state || {},
        state_ops: [
          AgentLoop::StateOps::SetPath.new(path: %i[__strategy__ initialized], value: true)
        ],
        effects: []
      )
    end

    def cmd(agent:, state:, instructions:, context:)
      AgentLoop::Strategies::Direct.new.cmd(agent: agent, state: state, instructions: instructions, context: context)
    end
  end

  class TickCountingStrategy < AgentLoop::Strategies::Base
    def cmd(agent:, state:, instructions:, context:)
      AgentLoop::Strategies::Direct.new.cmd(agent: agent, state: state, instructions: instructions, context: context)
    end

    def tick(instance:, runtime:, context: {})
      _runtime = runtime
      _context = context
      current = (instance.state || {}).fetch(:tick_count, 0)
      AgentLoop::Result.new(state: (instance.state || {}).merge(tick_count: current + 1), effects: [])
    end
  end

  class StrategyConfiguredAgent
    include AgentLoop::Agent

    default_state({ count: 0 })
    strategy InitTrackingStrategy
    route 'counter.increment', to: IncrementAction
  end

  class TickAgent
    include AgentLoop::Agent

    default_state({ tick_count: 0 })
    strategy TickCountingStrategy
    route 'counter.increment', to: IncrementAction
  end

  class FsmConfiguredAgent
    include AgentLoop::Agent

    default_state({ count: 0 })
    strategy AgentLoop::Strategies::Fsm,
             transitions: { idle: [:advance] },
             initial_step: :idle

    route 'workflow.advance', to: :advance
    route 'workflow.noop', to: :noop

    def advance(params, state:, context:)
      _context = context
      state.merge(count: state.fetch(:count, 0) + params.fetch(:by, 1))
    end

    def noop(_params, state:, context:)
      _context = context
      state
    end
  end

  def setup
    InitTrackingStrategy.reset!
    AgentLoop::Registry.clear
  end

  def teardown
    AgentLoop::Registry.clear
  end

  def test_strategy_init_runs_once_per_server_lifecycle
    runtime = AgentLoop::Runtime.new(
      strategy: AgentLoop::Strategies::Direct.new,
      effect_executor: AgentLoop::Effects::Executor.new(emit_adapter: AgentLoop::Adapters::Emitter::Null.new)
    )

    server = AgentLoop::AgentServer.start(agent: StrategyConfiguredAgent, id: 'strategy-init-1', runtime: runtime)

    first = AgentLoop::Signal.new(type: 'counter.increment', source: 'test', data: { by: 1 })
    second = AgentLoop::Signal.new(type: 'counter.increment', source: 'test', data: { by: 2 })
    server.call(first)
    server.call(second)

    assert_equal 1, InitTrackingStrategy.init_calls
    assert server.snapshot[:instance][:state].dig(:__strategy__, :initialized)
    assert_equal 3, server.snapshot[:instance][:state][:count]
  ensure
    server&.stop
  end

  def test_strategy_tick_signal_routes_to_strategy_tick_callback
    runtime = AgentLoop::Runtime.new(
      strategy: AgentLoop::Strategies::Direct.new,
      effect_executor: AgentLoop::Effects::Executor.new(emit_adapter: AgentLoop::Adapters::Emitter::Null.new)
    )

    server = AgentLoop::AgentServer.start(agent: TickAgent, id: 'strategy-tick-1', runtime: runtime)
    signal = AgentLoop::Signal.new(type: 'agent_loop.strategy.tick', source: 'test')

    result = server.call(signal)

    assert_equal :ok, result.status
    assert_equal 1, server.snapshot[:instance][:state][:tick_count]
  ensure
    server&.stop
  end

  def test_agent_level_strategy_overrides_runtime_default
    runtime = AgentLoop::Runtime.new(
      strategy: AgentLoop::Strategies::Direct.new,
      effect_executor: AgentLoop::Effects::Executor.new(emit_adapter: AgentLoop::Adapters::Emitter::Null.new)
    )

    instance = AgentLoop::Instance.new(agent_class: FsmConfiguredAgent, id: 'fsm-configured-1')

    ok_signal = AgentLoop::Signal.new(type: 'workflow.advance', source: 'test', data: { by: 2 })
    ok_result = runtime.call(instance, ok_signal)

    assert_equal :ok, ok_result.status

    bad_signal = AgentLoop::Signal.new(type: 'workflow.noop', source: 'test')
    bad_result = runtime.call(instance, bad_signal)

    assert_equal :error, bad_result.status
    assert_equal :invalid_transition, bad_result.effects.first.code
  end

  def test_direct_strategy_processes_instruction_lists
    agent = StrategyConfiguredAgent.new
    strategy = AgentLoop::Strategies::Direct.new
    instructions = [
      AgentLoop::Instruction.new(action: IncrementAction, params: { by: 1 }),
      AgentLoop::Instruction.new(action: IncrementAction, params: { by: 2 })
    ]

    result = strategy.cmd(agent: agent, state: agent.state, instructions: instructions, context: {})

    assert_equal :ok, result.status
    assert_equal 3, result.state[:count]
    assert_equal 0, result.effects.length
  end
end
