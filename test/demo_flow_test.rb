# frozen_string_literal: true

require 'test_helper'
require 'agent_loop'

class DemoFlowTest < Minitest::Test
  class CapturingEffectExecutor
    attr_reader :executed

    def initialize
      @executed = []
    end

    def execute_all(effects, instance:, runtime:)
      Array(effects).each do |effect|
        @executed << { effect: effect, instance_id: instance.id, runtime: runtime.class.name }
      end
    end
  end

  class TodoAgent
    include AgentLoop::Agent

    default_state({ todos: [], processed: 0 })
    route 'todo.added', to: :on_todo_added

    def on_todo_added(params, state:, context:)
      text = params.fetch('text')

      [
        state,
        [
          AgentLoop::StateOps::SetPath.new(path: [:todos], value: state.fetch(:todos) + [text]),
          AgentLoop::StateOps::SetPath.new(path: [:processed], value: state.fetch(:processed) + 1),
          AgentLoop::Effects::Emit.new(
            type: 'todo.accepted',
            data: {
              text: text,
              trace_id: context[:trace_id]
            }
          )
        ]
      ]
    end
  end

  def test_signal_to_result_flow_applies_state_ops_and_executes_effects
    effect_executor = CapturingEffectExecutor.new

    runtime = AgentLoop::Runtime.new(
      effect_executor: effect_executor,
      router: AgentLoop::Router.new,
      state_store: AgentLoop::StateStores::InMemory.new,
      state_op_applicator: AgentLoop::StateOps::Applicator.new
    )

    instance = AgentLoop::Instance.new(agent_class: TodoAgent, id: 'demo-1')

    signal = AgentLoop::Signal.new(
      type: 'todo.added',
      source: 'test.demo_flow',
      data: { 'text' => 'buy milk' }
    )

    result = runtime.call(instance, signal, context: { trace_id: 'trace-123' })

    assert_equal :ok, result.status
    assert_equal({ todos: ['buy milk'], processed: 1 }, result.state)
    assert_equal result.state, instance.state
    assert_equal :active, instance.status

    assert_equal 1, effect_executor.executed.size
    emitted = effect_executor.executed.first.fetch(:effect)

    assert_instance_of AgentLoop::Effects::Emit, emitted
    assert_equal 'todo.accepted', emitted.type
    assert_equal({ text: 'buy milk', trace_id: 'trace-123' }, emitted.data)
  end
end
