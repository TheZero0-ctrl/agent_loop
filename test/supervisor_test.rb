# frozen_string_literal: true

require 'test_helper'

class SupervisorTest < Minitest::Test
  class CountAction < AgentLoop::Action
    schema defaults: { by: 1 } do
      required(:by).filled(:integer)
    end

    def self.run(params, context)
      current = context.fetch(:state).fetch(:count, 0)
      { count: current + params.fetch(:by) }
    end
  end

  class ReceiverAgent
    include AgentLoop::Agent

    default_state(count: 0)
    route 'sensor.counted', to: CountAction
  end

  class ForwardingSensor
    include AgentLoop::Sensor

    def init(_config, context: {})
      [:ok, { agent_ref: context[:agent_ref] }]
    end

    def handle_event(event, state, context: {})
      _context = context
      return %i[error boom] if event == :fail

      signal = AgentLoop::Signal.new(type: 'sensor.counted', source: '/sensor/forwarding', data: { by: 1 })
      [:ok, state, [[:emit, signal]]]
    end
  end

  class CrashLoopSensor
    include AgentLoop::Sensor

    def init(_config, context: {})
      _context = context
      [:ok, {}, [[:schedule, 1, :tick]]]
    end

    def handle_event(_event, _state, context: {})
      _context = context
      %i[error crash_loop]
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
    AgentLoop::SensorRegistry.clear
  end

  def teardown
    AgentLoop::Registry.clear
    AgentLoop::SensorRegistry.clear
  end

  def test_supervisor_starts_agent_and_sensor_and_wires_signal_flow
    runtime = build_runtime
    supervisor = AgentLoop::Supervisor.start_link(
      children: [
        {
          id: 'agent-1',
          type: :agent_server,
          start: { runtime: runtime, agent: ReceiverAgent, id: 'agent-1', initial_state: { count: 0 } }
        },
        {
          id: 'sensor-1',
          type: :sensor_server,
          start: { sensor: ForwardingSensor, id: 'sensor-1', context: { agent_ref: 'agent-1' } }
        }
      ]
    )

    sensor_server = supervisor.whereis_child('sensor-1')
    sensor_server.event!(:incoming)

    agent_server = supervisor.whereis_child('agent-1')
    wait_until { agent_server.state[:count] == 1 }

    assert_equal :running, supervisor.status
    assert_equal 1, agent_server.state[:count]
  ensure
    supervisor&.stop(reason: :test_done)
  end

  def test_permanent_child_restarts_after_failure
    runtime = build_runtime
    supervisor = AgentLoop::Supervisor.start_link(
      monitor_interval: 0.01,
      children: [
        {
          id: 'sensor-1',
          type: :sensor_server,
          restart: :permanent,
          start: { sensor: ForwardingSensor, id: 'sensor-1' }
        },
        {
          id: 'agent-1',
          type: :agent_server,
          start: { runtime: runtime, agent: ReceiverAgent, id: 'agent-1', initial_state: { count: 0 } }
        }
      ]
    )

    old_server = supervisor.whereis_child('sensor-1')
    assert_raises(AgentLoop::SensorRuntimeError) { old_server.event!(:fail) }

    wait_until { supervisor.whereis_child('sensor-1') != old_server }

    refute_equal old_server, supervisor.whereis_child('sensor-1')
  ensure
    supervisor&.stop(reason: :test_done)
  end

  def test_transient_child_does_not_restart_after_clean_stop
    supervisor = AgentLoop::Supervisor.start_link(
      monitor_interval: 0.01,
      children: [
        {
          id: 'sensor-2',
          type: :sensor_server,
          restart: :transient,
          start: { sensor: ForwardingSensor, id: 'sensor-2' }
        }
      ]
    )

    supervisor.whereis_child('sensor-2').stop(reason: :manual)
    wait_until { supervisor.whereis_child('sensor-2').nil? }

    assert_nil supervisor.whereis_child('sensor-2')
  ensure
    supervisor&.stop(reason: :test_done)
  end

  def test_temporary_child_does_not_restart_after_failure
    supervisor = AgentLoop::Supervisor.start_link(
      monitor_interval: 0.01,
      children: [
        {
          id: 'sensor-3',
          type: :sensor_server,
          restart: :temporary,
          start: { sensor: ForwardingSensor, id: 'sensor-3' }
        }
      ]
    )

    server = supervisor.whereis_child('sensor-3')
    assert_raises(AgentLoop::SensorRuntimeError) { server.event!(:fail) }

    wait_until { supervisor.whereis_child('sensor-3').nil? }

    assert_nil supervisor.whereis_child('sensor-3')
  ensure
    supervisor&.stop(reason: :test_done)
  end

  def test_restart_intensity_marks_supervisor_failed
    supervisor = AgentLoop::Supervisor.start_link(
      monitor_interval: 0.01,
      max_restarts: 1,
      max_seconds: 0.2,
      children: [
        {
          id: 'sensor-crash',
          type: :sensor_server,
          restart: :permanent,
          start: { sensor: CrashLoopSensor, id: 'sensor-crash' }
        }
      ]
    )

    wait_until(timeout: 2) { supervisor.status == :failed }

    assert_equal :failed, supervisor.status
    assert_equal [], supervisor.which_children
  ensure
    supervisor&.stop(reason: :test_done)
  end

  private

  def build_runtime
    effect_executor = AgentLoop::Effects::Executor.new(
      emit_adapter: FakeEmitAdapter.new,
      server_manager: AgentLoop::ServerManager.new
    )
    AgentLoop::Runtime.new(effect_executor: effect_executor)
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    until yield
      raise 'condition not met before timeout' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end
end
