# frozen_string_literal: true

require 'test_helper'

class AgentRuntimeContractTest < Minitest::Test
  class AddAction < AgentLoop::Action
    schema defaults: { by: 1 } do
      required(:by).filled(:integer)
    end

    def self.run(params, context)
      { count: context.fetch(:state).fetch(:count, 0) + params.fetch(:by) }
    end
  end

  class HookedAgent
    include AgentLoop::Agent

    default_state({ count: 0 })

    class << self
      attr_reader :seen_before, :seen_after, :seen_error

      def on_before_cmd(agent:, instruction:, context:)
        @seen_before = { agent: agent.class.name, meta: context[:meta] }
        [instruction.with(params: instruction.params.merge(by: 2)), context.merge(meta: 'before')]
      end

      def on_after_cmd(agent:, instruction:, result:, context:)
        @seen_after = {
          agent: agent.class.name,
          by: instruction.params[:by],
          meta: context[:meta],
          count: result.state[:count]
        }
        result
      end

      def on_cmd_error(agent:, instruction:, error:, context:)
        @seen_error = {
          agent: agent.class.name,
          action: instruction.action,
          message: error.message,
          meta: context[:meta]
        }
        AgentLoop::Result.new(
          state: context.fetch(:state, agent.initial_state),
          effects: [AgentLoop::Effects::Error.new(code: :hook_handled, message: error.message)]
        )
      end
    end
  end

  class BrokenAction < AgentLoop::Action
    def self.run(_params, _context)
      raise 'boom'
    end
  end

  class RouteAgent
    include AgentLoop::Agent

    default_state({ count: 0 })
    route 'counter.add', to: AddAction
  end

  class TransitionAgent
    include AgentLoop::Agent

    default_state({ count: 0 })
    route 'noop', to: :noop

    def noop(_params, state:, context:)
      _context = context
      state
    end
  end

  class FailingEffectExecutor
    attr_reader :executed

    def initialize
      @executed = []
    end

    def execute(effect, instance:, runtime:)
      _runtime = runtime
      raise 'emit failed' if effect.is_a?(AgentLoop::Effects::Emit)

      @executed << { effect: effect.class.name, instance: instance.id }
      :ok
    end
  end

  class TwoEffectsAction < AgentLoop::Action
    def self.run(_params, _context)
      [
        {},
        [
          AgentLoop::Effects::Emit.new(type: 'counter.updated', data: { ok: false }),
          AgentLoop::Effects::Stop.new(reason: 'done')
        ]
      ]
    end
  end

  class EffectsAgent
    include AgentLoop::Agent

    default_state({})
    route 'effects.run', to: TwoEffectsAction
  end

  def test_agent_cmd_runs_before_and_after_hooks
    agent = HookedAgent.new
    instruction = AgentLoop::Instruction.new(action: AddAction, params: { by: 1 })

    result = agent.cmd(agent.state, instruction, context: { meta: 'start' })

    assert_equal 2, result.state[:count]
    assert_equal HookedAgent.name, HookedAgent.seen_before[:agent]
    assert_equal 'before', HookedAgent.seen_after[:meta]
    assert_equal 2, HookedAgent.seen_after[:by]
  end

  def test_agent_cmd_error_hook_can_convert_exception_into_result
    agent = HookedAgent.new
    instruction = AgentLoop::Instruction.new(action: BrokenAction)

    result = agent.cmd(agent.state, instruction, context: { meta: 'err', state: agent.state })

    assert_equal :hook_handled, result.effects.first.code
    assert_equal BrokenAction, HookedAgent.seen_error[:action]
    assert_equal 'err', HookedAgent.seen_error[:meta]
  end

  def test_runtime_wraps_invalid_transition_as_error_result
    strategy = AgentLoop::Strategies::Fsm.new(transitions: { idle: [:allowed] }, initial_step: :idle)
    emit_adapter = AgentLoop::Adapters::Emitter::InProcess.new
    runtime = AgentLoop::Runtime.new(
      strategy: strategy,
      effect_executor: AgentLoop::Effects::Executor.new(emit_adapter: emit_adapter)
    )

    instance = AgentLoop::Instance.new(agent_class: TransitionAgent, id: 'fsm-1')
    signal = AgentLoop::Signal.new(type: 'noop', source: 'test')

    result = runtime.call(instance, signal)

    assert_equal :error, result.status
    assert_equal :invalid_transition, result.effects.first.code
    assert_equal :failed, instance.status
  end

  def test_effect_pipeline_continues_after_single_effect_failure
    runtime = AgentLoop::Runtime.new(
      effect_executor: FailingEffectExecutor.new
    )

    instance = AgentLoop::Instance.new(agent_class: EffectsAgent, id: 'effects-1')
    signal = AgentLoop::Signal.new(type: 'effects.run', source: 'test')

    result = runtime.call(instance, signal)

    assert_equal :error, result.status
    assert_equal :effect_execution_failed, result.error[:code]
    assert_equal :failed, instance.status
    assert_equal :effect_execution_failed, instance.metadata.dig(:last_error, :code)
  end

  def test_schedule_failure_is_reflected_in_returned_result
    emit_adapter = AgentLoop::Adapters::Emitter::InProcess.new
    runtime = AgentLoop::Runtime.new(
      effect_executor: AgentLoop::Effects::Executor.new(emit_adapter: emit_adapter)
    )

    scheduled_agent = Class.new do
      include AgentLoop::Agent

      default_state({ count: 0 })
      route 'counter.defer', to: :defer

      def defer(_params, state:, context:)
        _context = context
        [
          state,
          [
            AgentLoop::Effects::Schedule.new(
              delay_ms: 1000,
              signal: AgentLoop::Signal.new(type: 'counter.increment', source: 'test', data: { 'by' => 2 })
            )
          ]
        ]
      end
    end

    instance = AgentLoop::Instance.new(agent_class: scheduled_agent, id: 'schedule-fail')
    result = runtime.call(instance, AgentLoop::Signal.new(type: 'counter.defer', source: 'test'))

    assert_equal :error, result.status
    assert_equal :effect_execution_failed, result.error[:code]
    assert_equal :failed, instance.status
    assert_equal :effect_execution_failed, instance.metadata.dig(:last_error, :code)
  end

  def test_agent_server_wraps_runtime_and_snapshot
    emit_adapter = AgentLoop::Adapters::Emitter::InProcess.new
    runtime = AgentLoop::Runtime.new(effect_executor: AgentLoop::Effects::Executor.new(emit_adapter: emit_adapter))
    instance = AgentLoop::Instance.new(agent_class: RouteAgent, id: 'server-1')
    server = AgentLoop::AgentServer.new(runtime: runtime, instance: instance)

    result = server.call(AgentLoop::Signal.new(type: 'counter.add', source: 'test', data: { by: 3 }))
    snapshot = server.snapshot

    assert_equal :ok, result.status
    assert_equal 3, snapshot[:instance][:state][:count]
    assert_equal 'server-1', snapshot[:instance][:id]
  end
end
