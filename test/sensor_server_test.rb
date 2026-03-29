# frozen_string_literal: true

require 'test_helper'

class SensorServerTest < Minitest::Test
  class CountSignalAction < AgentLoop::Action
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
    route 'sensor.counted', to: CountSignalAction
  end

  class CountingSensor
    include AgentLoop::Sensor

    schema do
      optional(:interval_ms).filled(:integer)
    end

    def init(config, context: {})
      effects = []
      effects << [:schedule, config[:interval_ms], :tick] if config[:interval_ms]
      [:ok, { seen: 0, agent_ref: context[:agent_ref] }, effects]
    end

    def handle_event(event, state, context: {})
      _context = context
      return [:ok, state] if event == :noop

      next_seen = state.fetch(:seen) + 1
      signal = AgentLoop::Signal.new(
        type: 'sensor.counted',
        source: '/sensor/counting',
        data: { by: 1 }
      )

      [:ok, state.merge(seen: next_seen), [[:emit, signal]]]
    end
  end

  class AdapterEffectSensor
    include AgentLoop::Sensor

    def init(_config, context: {})
      _context = context
      [:ok, { connected: false }]
    end

    def handle_event(event, state, context: {})
      _context = context
      return [:ok, state] unless event == :wire

      effects = [
        [:connect, :bus, { durable: true }],
        [:subscribe, :bus, 'orders'],
        [:unsubscribe, :bus, 'orders'],
        %i[disconnect bus]
      ]

      [:ok, state.merge(connected: true), effects]
    end
  end

  class RecordingAdapter < AgentLoop::SensorAdapters::Base
    attr_reader :events

    def initialize
      @events = []
    end

    def connect(_sensor_server, opts: {})
      events << [:connect, opts]
      :ok
    end

    def disconnect(_sensor_server)
      events << [:disconnect]
      :ok
    end

    def subscribe(_sensor_server, topic:)
      events << [:subscribe, topic]
      :ok
    end

    def unsubscribe(_sensor_server, topic:)
      events << [:unsubscribe, topic]
      :ok
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

  def test_sensor_event_emits_signal_to_live_agent_server
    agent_server = build_agent_server(id: 'receiver-1')
    sensor_server = AgentLoop::SensorServer.start(
      sensor: CountingSensor,
      id: 'sensor-1',
      context: { agent_ref: 'receiver-1' }
    )

    result = sensor_server.event!(:incoming)

    assert_equal :ok, result.status
    wait_until { agent_server.state[:count] == 1 }

    assert_equal 1, agent_server.state[:count]
  ensure
    sensor_server&.stop
    agent_server&.stop
  end

  def test_schedule_effect_reinjects_tick_event
    sensor_server = AgentLoop::SensorServer.start(
      sensor: CountingSensor,
      id: 'sensor-2',
      config: { interval_ms: 10 }
    )

    wait_until { sensor_server.state[:seen] >= 1 }

    assert_operator sensor_server.snapshot[:server][:active_timers], :>=, 0
  ensure
    sensor_server&.stop
  end

  def test_connect_subscribe_effects_execute_via_adapter
    adapter = RecordingAdapter.new
    sensor_server = AgentLoop::SensorServer.start(
      sensor: AdapterEffectSensor,
      id: 'sensor-3',
      adapters: { bus: adapter }
    )

    sensor_server.event!(:wire)

    assert_equal [
      [:connect, { durable: true }],
      [:subscribe, 'orders'],
      [:unsubscribe, 'orders'],
      [:disconnect]
    ], adapter.events
  ensure
    sensor_server&.stop
  end

  def test_event_queue_overflow_raises
    sensor_server = AgentLoop::SensorServer.start(
      sensor: CountingSensor,
      id: 'sensor-4',
      max_event_queue_size: 0
    )

    assert_raises(AgentLoop::SensorServer::QueueOverflow) do
      sensor_server.event(:incoming)
    end
  ensure
    sensor_server&.stop
  end

  private

  def build_agent_server(id:)
    effect_executor = AgentLoop::Effects::Executor.new(
      emit_adapter: FakeEmitAdapter.new,
      server_manager: AgentLoop::ServerManager.new
    )
    runtime = AgentLoop::Runtime.new(effect_executor: effect_executor)

    AgentLoop::AgentServer.start(
      runtime: runtime,
      agent: ReceiverAgent,
      id: id,
      initial_state: { count: 0 }
    )
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    until yield
      raise 'condition not met before timeout' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end
end
