# frozen_string_literal: true

require 'test_helper'

class AgentServerTest < Minitest::Test
  class IncrementAction < AgentLoop::Action
    schema defaults: { by: 1, pause_ms: 0 } do
      required(:by).filled(:integer)
      required(:pause_ms).filled(:integer)
    end

    def self.run(params, context)
      sleep(params.fetch(:pause_ms) / 1000.0)
      current = context.fetch(:state).fetch(:count, 0)
      { count: current + params.fetch(:by) }
    end
  end

  class StopAction < AgentLoop::Action
    def self.run(_params, context)
      current = context.fetch(:state).fetch(:count, 0)
      [
        { count: current },
        [AgentLoop::Effects::Stop.new(reason: :completed)]
      ]
    end
  end

  class CompleteAction < AgentLoop::Action
    def self.run(_params, context)
      current = context.fetch(:state).fetch(:count, 0)
      { count: current, status: :completed }
    end
  end

  class SpawnChildAction < AgentLoop::Action
    def self.run(_params, context)
      current = context.fetch(:state)
      [
        current,
        [
          AgentLoop::Effects::Spawn.new(
            agent_class: ChildAgent,
            id: 'child-1',
            tag: 'worker-1',
            initial_state: { count: 0 }
          )
        ]
      ]
    end
  end

  class SpawnContinueChildAction < AgentLoop::Action
    def self.run(_params, context)
      current = context.fetch(:state)
      [
        current,
        [
          AgentLoop::Effects::Spawn.new(
            agent_class: ChildAgent,
            id: 'child-continue',
            tag: 'worker-continue',
            initial_state: { count: 0 },
            on_parent_death: :continue
          )
        ]
      ]
    end
  end

  class SpawnOrphanChildAction < AgentLoop::Action
    def self.run(_params, context)
      current = context.fetch(:state)
      [
        current,
        [
          AgentLoop::Effects::Spawn.new(
            agent_class: OrphanAwareChildAgent,
            id: 'child-orphan',
            tag: 'worker-orphan',
            initial_state: { orphaned: false },
            on_parent_death: :emit_orphan
          )
        ]
      ]
    end
  end

  class ChildCompleteAction < AgentLoop::Action
    def self.run(_params, context)
      current = context.fetch(:state).fetch(:count, 0)
      { count: current + 1, status: :completed }
    end
  end

  class BurstEffectAction < AgentLoop::Action
    def self.run(_params, context)
      current = context.fetch(:state).fetch(:count, 0)
      [
        { count: current },
        [
          AgentLoop::Effects::Emit.new(type: 'counter.one', data: { count: current }),
          AgentLoop::Effects::Emit.new(type: 'counter.two', data: { count: current })
        ]
      ]
    end
  end

  class CounterAgent
    include AgentLoop::Agent

    default_state(count: 0)
    route 'counter.increment', to: IncrementAction
    route 'counter.stop', to: StopAction
    route 'counter.complete', to: CompleteAction
    route 'counter.burst', to: BurstEffectAction
  end

  class ChildAgent
    include AgentLoop::Agent

    default_state(count: 0)
    route 'child.complete', to: ChildCompleteAction
  end

  class OrphanAwareChildAgent
    include AgentLoop::Agent

    default_state(orphaned: false)
    route 'agent_loop.parent.orphaned', to: :on_orphaned

    def on_orphaned(_params, state:, context:)
      _state = state
      _context = context
      { orphaned: true }
    end
  end

  class ParentAgent
    include AgentLoop::Agent

    default_state(spawned: false, completed_children: [])
    route 'parent.spawn', to: SpawnChildAction
    route 'parent.spawn_continue', to: SpawnContinueChildAction
    route 'parent.spawn_orphan', to: SpawnOrphanChildAction
    route 'agent_loop.child.completed', to: :on_child_completed

    def on_child_completed(params, state:, context:)
      _context = context

      {
        spawned: true,
        completed_children: state.fetch(:completed_children, []) + [params.fetch(:tag)]
      }
    end
  end

  class FakeEmitAdapter
    attr_reader :emitted

    def initialize
      @emitted = []
    end

    def emit(_signal, target: nil)
      emitted << { target: target }
      :ok
    end
  end

  class TrackingServerManager
    attr_reader :started_ids

    def initialize(registry: AgentLoop::Registry)
      @registry = registry
      @started_ids = []
    end

    def start(**kwargs)
      @started_ids << kwargs.fetch(:instance).id
      AgentLoop::AgentServer.start(**kwargs, registry: @registry)
    end
  end

  def setup
    AgentLoop::Registry.clear
  end

  def teardown
    AgentLoop::Registry.clear
  end

  def test_start_registers_server_and_sync_call_flows_through_mailbox
    server = build_server(id: 'counter-1')

    result = server.call(AgentLoop::Signal.new(type: 'counter.increment', source: 'test', data: { by: 2 }))

    assert_equal server, AgentLoop::AgentServer.whereis('counter-1')
    assert_equal :ok, result.status
    assert_equal 2, result.state[:count]
    assert_equal 2, server.state[:count]
    assert_equal :idle, server.status
  ensure
    server&.stop
  end

  def test_cast_processes_signals_asynchronously_on_server_mailbox
    server = build_server(id: 'counter-2')

    assert_equal :ok, server.cast(AgentLoop::Signal.new(type: 'counter.increment', source: 'test', data: { by: 3 }))

    wait_until { server.state[:count] == 3 }

    assert_equal 3, server.state[:count]
    assert_equal :idle, server.status
  ensure
    server&.stop
  end

  def test_call_and_cast_share_ordered_mailbox_processing
    server = build_server(id: 'counter-3')

    caller = Thread.new do
      server.call(
        AgentLoop::Signal.new(type: 'counter.increment', source: 'test', data: { by: 2, pause_ms: 50 })
      )
    end

    sleep 0.01
    server.cast(AgentLoop::Signal.new(type: 'counter.increment', source: 'test', data: { by: 1 }))
    caller.join
    wait_until { server.state[:count] == 3 }

    assert_equal 3, server.state[:count]
    assert_equal :idle, server.status
  ensure
    server&.stop
  end

  def test_await_completion_returns_terminal_snapshot
    server = build_server(id: 'counter-4')

    server.cast(AgentLoop::Signal.new(type: 'counter.stop', source: 'test'))
    snapshot = server.await_completion(timeout: 1)

    refute_nil snapshot
    assert_equal :stopped, snapshot[:instance][:status]
    assert_equal :stopped, snapshot[:server][:status]
  ensure
    server&.stop
  end

  def test_completed_state_becomes_terminal_server_status
    server = build_server(id: 'counter-5')

    result = server.call(AgentLoop::Signal.new(type: 'counter.complete', source: 'test'))

    assert_equal :ok, result.status
    assert_equal :completed, server.status
    assert_predicate server, :completed?
    assert_equal :completed, server.await_completion(timeout: 1)[:server][:status]
  ensure
    server&.stop
  end

  def test_spawn_starts_child_server_and_notifies_parent_on_completion
    server_manager = TrackingServerManager.new
    parent = build_server(id: 'parent-1', agent_class: ParentAgent,
                          initial_state: { spawned: false, completed_children: [] },
                          server_manager: server_manager)

    parent.call(AgentLoop::Signal.new(type: 'parent.spawn', source: 'test'))
    child = AgentLoop::AgentServer.whereis('child-1')

    refute_nil child
    assert_equal ['child-1'], server_manager.started_ids
    assert_equal 'child-1', parent.instance.children.fetch('worker-1').fetch(:id)

    child.call(AgentLoop::Signal.new(type: 'child.complete', source: 'test'))

    wait_until { parent.state[:completed_children].include?('worker-1') }

    assert_equal ['worker-1'], parent.state[:completed_children]
    assert_equal :completed, child.status
  ensure
    child&.stop
    parent&.stop
  end

  def test_parent_ignores_unhandled_internal_child_started_signal_without_failing
    parent = build_server(id: 'parent-started', agent_class: ParentAgent,
                          initial_state: { spawned: false, completed_children: [] })

    parent.call(AgentLoop::Signal.new(type: 'parent.spawn', source: 'test'))

    wait_until { parent.instance.children.fetch('worker-1').fetch(:status) == :started }

    assert_equal :idle, parent.status
  ensure
    AgentLoop::AgentServer.whereis('child-1')&.stop
    parent&.stop
  end

  def test_parent_stop_stops_managed_children
    parent = build_server(id: 'parent-2', agent_class: ParentAgent,
                          initial_state: { spawned: false, completed_children: [] })

    parent.call(AgentLoop::Signal.new(type: 'parent.spawn', source: 'test'))
    child = AgentLoop::AgentServer.whereis('child-1')

    refute_nil child
    parent.stop(reason: :shutdown)

    wait_until { AgentLoop::AgentServer.whereis('child-1').nil? }

    assert_nil AgentLoop::AgentServer.whereis('child-1')
  ensure
    child&.stop
    parent&.stop
  end

  def test_parent_stop_with_continue_policy_leaves_child_running
    parent = build_server(id: 'parent-continue', agent_class: ParentAgent,
                          initial_state: { spawned: false, completed_children: [] })

    parent.call(AgentLoop::Signal.new(type: 'parent.spawn_continue', source: 'test'))
    child = AgentLoop::AgentServer.whereis('child-continue')

    refute_nil child
    parent.stop(reason: :shutdown)

    wait_until { AgentLoop::AgentServer.whereis('child-continue') == child }

    assert_equal child, AgentLoop::AgentServer.whereis('child-continue')
    assert_equal :idle, child.status
  ensure
    child&.stop
    parent&.stop
  end

  def test_parent_stop_with_emit_orphan_policy_notifies_child
    parent = build_server(id: 'parent-orphan', agent_class: ParentAgent,
                          initial_state: { spawned: false, completed_children: [] })

    parent.call(AgentLoop::Signal.new(type: 'parent.spawn_orphan', source: 'test'))
    child = AgentLoop::AgentServer.whereis('child-orphan')

    refute_nil child
    parent.stop(reason: :shutdown)

    wait_until { child.state[:orphaned] }

    assert(child.state[:orphaned])
    assert_equal :idle, child.status
  ensure
    child&.stop
    parent&.stop
  end

  def test_deliver_scheduled_signal_uses_live_server_when_available
    server = build_server(id: 'counter-6')

    result = AgentLoop::AgentServer.deliver_scheduled_signal(
      payload: scheduled_payload(instance_id: 'counter-6', by: 4),
      runtime: server.runtime
    )

    assert_equal :ok, result.status
    assert_equal 4, server.state[:count]
  ensure
    server&.stop
  end

  def test_deliver_scheduled_signal_falls_back_to_runtime_call_without_live_server
    state_store = AgentLoop::StateStores::InMemory.new
    runtime = build_runtime(state_store: state_store)

    result = AgentLoop::AgentServer.deliver_scheduled_signal(
      payload: scheduled_payload(instance_id: 'counter-7', by: 5),
      runtime: runtime
    )

    assert_equal :ok, result.status
    assert_equal 5, result.state[:count]
    assert_equal 5, state_store.load('counter-7')[:count]
  end

  def test_signal_queue_overflow_raises_for_extra_enqueues
    server = build_server(id: 'counter-8', max_signal_queue_size: 0)

    error = assert_raises(AgentLoop::AgentServer::QueueOverflow) do
      server.cast(AgentLoop::Signal.new(type: 'counter.increment', source: 'test', data: { by: 1 }))
    end

    assert_match 'Signal queue overflow', error.message
  ensure
    server&.stop
  end

  def test_effect_queue_overflow_marks_server_failed
    server = build_server(id: 'counter-9', max_effect_queue_size: 1)

    error = assert_raises(AgentLoop::AgentServer::QueueOverflow) do
      server.call(AgentLoop::Signal.new(type: 'counter.burst', source: 'test'))
    end

    assert_match 'Effect queue overflow', error.message
    assert_equal :failed, server.status
    assert_equal :failed, server.instance.status
  ensure
    server&.stop
  end

  private

  def build_server(id:, agent_class: CounterAgent, initial_state: { count: 0 },
                   max_signal_queue_size: AgentLoop::AgentServer::DEFAULT_MAX_QUEUE_SIZE,
                   max_effect_queue_size: AgentLoop::AgentServer::DEFAULT_MAX_QUEUE_SIZE,
                   server_manager: nil)
    runtime = build_runtime(server_manager: server_manager)

    AgentLoop::AgentServer.start(
      runtime: runtime,
      agent_class: agent_class,
      id: id,
      initial_state: initial_state,
      max_signal_queue_size: max_signal_queue_size,
      max_effect_queue_size: max_effect_queue_size
    )
  end

  def build_runtime(state_store: AgentLoop::StateStores::InMemory.new, server_manager: nil)
    emit_adapter = FakeEmitAdapter.new
    effect_executor = AgentLoop::Effects::Executor.new(
      emit_adapter: emit_adapter,
      server_manager: server_manager || AgentLoop::ServerManager.new
    )
    AgentLoop::Runtime.new(
      effect_executor: effect_executor,
      state_store: state_store
    )
  end

  def scheduled_payload(instance_id:, by:)
    {
      'instance_id' => instance_id,
      'agent_class' => CounterAgent.name,
      'signal' => AgentLoop::Signal.new(
        type: 'counter.increment',
        source: 'test.schedule',
        data: { 'by' => by }
      ).to_h,
      'meta' => { 'origin' => 'test' }
    }
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    until yield
      raise 'condition not met before timeout' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end
end
