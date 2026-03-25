# frozen_string_literal: true

require "test_helper"

class RuntimeSignalFlowTest < Minitest::Test
  class IncrementAction < AgentLoop::Action
    schema defaults: { by: 1 } do
      required(:by).filled(:integer)
    end

    def self.run(params, context)
      current = context.fetch(:state).fetch(:count, 0)
      [
        { count: current + params.fetch(:by) },
        [AgentLoop::Effects::Emit.new(type: "counter.updated", data: { count: current + params.fetch(:by) })]
      ]
    end
  end

  class CounterAgent
    include AgentLoop::Agent

    default_state({ count: 0 })
    route "counter.increment", to: IncrementAction
  end

  def build_runtime
    emit_adapter = AgentLoop::Adapters::Emitter::InProcess.new
    effect_executor = AgentLoop::Effects::Executor.new(emit_adapter: emit_adapter)
    runtime = AgentLoop::Runtime.new(effect_executor: effect_executor)
    [runtime, emit_adapter]
  end

  def test_cast_and_drain_processes_queued_signals
    runtime, _emit_adapter = build_runtime
    instance = AgentLoop::Instance.new(agent_class: CounterAgent, id: "counter-queue")
    signal = AgentLoop::Signal.new(type: "counter.increment", source: "test", data: { "by" => 3 })

    assert_equal :ok, runtime.cast(instance, signal)
    assert_equal 1, runtime.drain
    assert_equal 3, instance.state[:count]
  end

  def test_emit_inherits_trace_metadata_from_last_signal
    runtime, emit_adapter = build_runtime
    instance = AgentLoop::Instance.new(agent_class: CounterAgent, id: "counter-meta")

    signal = AgentLoop::Signal.new(
      type: "counter.increment",
      source: "test",
      data: { "by" => 2 },
      metadata: { trace_id: "trace-123", correlation_id: "corr-123" }
    )

    runtime.call(instance, signal)

    emitted = emit_adapter.events.first.fetch(:signal)
    assert_equal "trace-123", emitted.metadata[:trace_id]
    assert_equal "corr-123", emitted.metadata[:correlation_id]
    assert_equal signal.id, emitted.metadata[:causation_id]
  end
end
