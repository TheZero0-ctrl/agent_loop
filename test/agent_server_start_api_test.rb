# frozen_string_literal: true

require 'test_helper'

class AgentServerStartApiTest < Minitest::Test
  class IncrementAction < AgentLoop::Action
    schema defaults: { by: 1 } do
      required(:by).filled(:integer)
    end

    def self.run(params, context)
      current = context.fetch(:state).fetch(:count, 0)
      { count: current + params.fetch(:by) }
    end
  end

  class CounterAgent
    include AgentLoop::Agent

    default_state(count: 0)
    route 'counter.increment', to: IncrementAction
  end

  class PrebuiltAgent
    attr_reader :id, :state

    def initialize(id:, state:)
      @id = id
      @state = state
    end
  end

  class FakeEmitAdapter
    def emit(_signal, target: nil)
      _target = target
      :ok
    end
  end

  def setup
    AgentLoop::Registry.clear
    AgentLoop.reset_runtime!
  end

  def teardown
    AgentLoop::Registry.clear
    AgentLoop.reset_runtime!
  end

  def test_start_with_agent_uses_default_runtime
    runtime = build_runtime
    AgentLoop.runtime = runtime

    server = AgentLoop::AgentServer.start(agent: CounterAgent)
    result = server.call(AgentLoop::Signal.new(type: 'counter.increment', source: 'test', data: { by: 2 }))

    assert_equal :ok, result.status
    assert_equal 2, server.state[:count]
    assert_equal runtime, server.runtime
  ensure
    server&.stop
  end

  def test_start_link_accepts_id_and_initial_state
    runtime = build_runtime
    AgentLoop.runtime = runtime

    server = AgentLoop::AgentServer.start_link(
      agent: CounterAgent,
      id: 'order-42',
      initial_state: { count: 10 }
    )

    assert_equal server, AgentLoop::AgentServer.whereis('order-42')
    assert_equal 10, server.state[:count]
  ensure
    server&.stop
  end

  def test_start_with_prebuilt_agent_object_and_agent_module
    runtime = build_runtime

    prebuilt = PrebuiltAgent.new(id: 'prebuilt-1', state: { count: 7 })
    server = AgentLoop::AgentServer.start(agent: prebuilt, agent_module: CounterAgent, runtime: runtime)

    assert_equal 'prebuilt-1', server.instance.id
    assert_equal 7, server.state[:count]
  ensure
    server&.stop
  end

  def test_start_generates_id_when_not_provided
    runtime = build_runtime

    server = AgentLoop::AgentServer.start(agent: CounterAgent, runtime: runtime)

    refute_nil server.instance.id
    refute_empty server.instance.id
  ensure
    server&.stop
  end

  def test_configure_runtime_builder_applies_to_start
    AgentLoop.configure do |config|
      config.runtime_builder = lambda {
        build_runtime
      }
    end

    server = AgentLoop::AgentServer.start(agent: CounterAgent)

    assert_instance_of AgentLoop::Runtime, server.runtime
  ensure
    server&.stop
  end

  private

  def build_runtime
    effect_executor = AgentLoop::Effects::Executor.new(
      emit_adapter: FakeEmitAdapter.new,
      server_manager: AgentLoop::ServerManager.new
    )

    AgentLoop::Runtime.new(effect_executor: effect_executor)
  end
end
