# frozen_string_literal: true

require 'test_helper'

class EffectsScheduleTest < Minitest::Test
  class FakeJob
    class << self
      attr_reader :calls

      def reset!
        @calls = []
      end

      def set(**opts)
        (@calls ||= []) << { kind: :set, opts: opts }
        JobProxy.new(self, opts)
      end

      def perform_later(payload)
        (@calls ||= []) << { kind: :perform_later, payload: payload }
        :enqueued
      end
    end

    class JobProxy
      def initialize(job_class, opts)
        @job_class = job_class
        @opts = opts
      end

      def set(**)
        @job_class.set(**@opts, **)
      end

      def perform_later(payload)
        @job_class.calls << { kind: :perform_later, payload: payload, opts: @opts }
        :enqueued
      end
    end
  end

  class FakeEmitAdapter
    attr_reader :emitted

    def initialize
      @emitted = []
    end

    def emit(signal, target: nil)
      emitted << { signal: signal, target: target }
      :ok
    end
  end

  class NoopAgent
    include AgentLoop::Agent
  end

  def setup
    FakeJob.reset!
  end

  def test_emit_uses_emit_adapter
    emit_adapter = FakeEmitAdapter.new
    executor = AgentLoop::Effects::Executor.new(emit_adapter: emit_adapter)
    runtime = AgentLoop::Runtime.new(effect_executor: executor)
    instance = AgentLoop::Instance.new(agent_class: NoopAgent, id: 'inst-1')

    effect = AgentLoop::Effects::Emit.new(type: 'event.created', data: { ok: true }, target: 'sink')

    executor.execute(effect, instance: instance, runtime: runtime)

    assert_equal 1, emit_adapter.emitted.size
    assert_equal 'event.created', emit_adapter.emitted.first[:signal].type
    assert_equal 'sink', emit_adapter.emitted.first[:target]
  end

  def test_schedule_enqueues_job
    emit_adapter = FakeEmitAdapter.new
    executor = AgentLoop::Effects::Executor.new(
      emit_adapter: emit_adapter,
      scheduled_signal_job_class: FakeJob
    )
    runtime = AgentLoop::Runtime.new(effect_executor: executor)
    instance = AgentLoop::Instance.new(agent_class: NoopAgent, id: 'inst-2')

    effect = AgentLoop::Effects::Schedule.new(
      delay_ms: 2_500,
      signal: AgentLoop::Signal.new(type: 'event.delayed', source: 'test', data: { count: 2 }),
      meta: { trace_id: 'trace-123' }
    )

    executor.execute(effect, instance: instance, runtime: runtime)

    perform = FakeJob.calls.find { |entry| entry[:kind] == :perform_later }

    refute_nil perform
    assert_equal 'inst-2', perform[:payload]['instance_id']
    assert_equal 'EffectsScheduleTest::NoopAgent', perform[:payload]['agent_class']
    assert_equal 'event.delayed', perform[:payload]['signal'][:type]
    assert_equal 'trace-123', perform[:payload]['meta'][:trace_id]

    wait_set = FakeJob.calls.find { |entry| entry[:kind] == :set && entry[:opts].key?(:wait) }

    refute_nil wait_set
    assert_equal 0, emit_adapter.emitted.size
  end
end
