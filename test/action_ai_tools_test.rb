# frozen_string_literal: true

require 'test_helper'

unless defined?(RubyLLM::Tool)
  module RubyLLM
    class Tool
      class << self
        attr_reader :_description, :_params

        def description(text = nil)
          return @_description unless text

          @_description = text
        end

        def params(schema = nil)
          @_params = schema
        end
      end

      def call(args)
        execute(**args.transform_keys(&:to_sym))
      end
    end
  end
end

class ActionAiToolsTest < Minitest::Test
  class LookupCustomer < AgentLoop::Action
    name 'lookup_customer'
    description 'Finds a customer by email address'

    schema defaults: { include_notes: false } do
      required(:email).filled(:string)
      optional(:include_notes).filled(:bool)
    end

    output_schema do
      required(:customer_id).filled(:string)
    end

    def self.run(params, _context)
      {
        customer_id: 'cus_123',
        email: params.fetch(:email),
        include_notes: params.fetch(:include_notes),
        passthrough: 'ok'
      }
    end
  end

  class EffectfulToolAction < AgentLoop::Action
    name 'effectful_tool_action'

    schema do
      required(:id).filled(:string)
    end

    def self.run(params, _context)
      [
        { id: params.fetch(:id) },
        [AgentLoop::Effects::Emit.new(type: 'bad.effect')]
      ]
    end
  end

  class ToolRuntimeAgent
    include AgentLoop::Agent

    default_state({ tool_result: nil })
    route 'tool.completed', to: :on_tool_completed

    def on_tool_completed(params, state:, context:)
      result = params.fetch('result')
      result_state = result[:state] || result['state']
      result_action = result[:action] || result['action']
      output_patch = result[:output_patch] || result['output_patch']
      tool_call_id = params['tool_call_id']
      [
        state,
        [
          AgentLoop::StateOps::SetPath.new(path: [:tool_result], value: result_state),
          AgentLoop::StateOps::SetPath.new(path: [:tool_action], value: result_action),
          AgentLoop::StateOps::SetPath.new(path: [:tool_output_patch], value: output_patch),
          AgentLoop::StateOps::SetPath.new(path: [:tool_call_id], value: tool_call_id),
          AgentLoop::StateOps::SetPath.new(path: [:instance_id], value: context[:instance_id])
        ]
      ]
    end
  end

  class StrictLookup < AgentLoop::Action
    name 'strict_lookup'
    strict true

    schema do
      required(:id).filled(:string)
    end

    def self.run(params, _context)
      { id: params.fetch(:id) }
    end
  end

  class ComplexSchemaAction < AgentLoop::Action
    name 'complex_schema'
    strict true
    param_descriptions(
      user: {
        email: 'Customer email'
      },
      status: 'Lifecycle status'
    )

    schema do
      required(:user).hash do
        required(:email).filled(:string)
        optional(:age).filled(:integer)
      end
      required(:tags).array(:string)
      required(:status).value(included_in?: %w[pending active])
      optional(:nickname).maybe(:string)
    end

    def self.run(_params, _context)
      { ok: true }
    end
  end

  def test_to_tool_generates_generic_tool_descriptor
    tool = LookupCustomer.to_tool

    assert_equal 'lookup_customer', tool[:name]
    assert_equal 'Finds a customer by email address', tool[:description]
    params = tool.fetch(:parameters)

    assert_equal 'object', params[:type]
    assert params[:additionalProperties]
    assert_includes params[:required], 'email'
  end

  def test_schema_to_json_schema_supports_strict_mode
    strict_schema = LookupCustomer.parameters_json_schema(strict: true)

    refute strict_schema[:additionalProperties]
    assert strict_schema[:strict]
  end

  def test_rubyllm_tool_adapter_queues_and_runtime_executes_calls
    sink = AgentLoop::AI::InMemoryToolExecSink.new
    tools = AgentLoop::AI::ToolAdapter.from_actions([LookupCustomer])

    response = AgentLoop::AI::ToolAdapter.with_runtime(
      instance_id: 'tool-runtime-1',
      sink: sink,
      callback_event: 'tool.completed',
      context: { trace_id: 'trace-1', correlation_id: 'corr-1' }
    ) do
      tools.first.call({ 'email' => 'jane@example.com' })
    end

    assert response[:queued]
    assert_equal 'tool-runtime-1', response[:instance_id]
    assert_equal 1, sink.size(instance_id: 'tool-runtime-1')

    tool_adapter = AgentLoop::Adapters::Tools::ActionRegistry.new(actions: [LookupCustomer])
    emit_adapter = AgentLoop::Adapters::Emitter::InProcess.new
    effect_executor = AgentLoop::Effects::Executor.new(emit_adapter: emit_adapter, tool_adapter: tool_adapter)
    runtime = AgentLoop::Runtime.new(effect_executor: effect_executor)

    instance = AgentLoop::Instance.new(agent_class: ToolRuntimeAgent, id: 'tool-runtime-1')

    AgentLoop::AI::ToolAdapter.run_deferred!(runtime: runtime, instance: instance, sink: sink)

    assert_equal 0, sink.size(instance_id: 'tool-runtime-1')
    assert_equal 'lookup_customer', instance.state[:tool_action]
    assert_equal 'cus_123', instance.state.dig(:tool_result, :customer_id)
    assert_equal 'cus_123', instance.state.dig(:tool_output_patch, :customer_id)
    assert instance.state[:tool_call_id]
  end

  def test_rubyllm_tool_adapter_uses_per_action_strict_mode_by_default
    tools = AgentLoop::AI::ToolAdapter.from_actions([StrictLookup])

    schema = tools.first.class._params
    additional = schema['additionalProperties']
    additional = schema[:additionalProperties] if additional.nil?
    strict = schema['strict']
    strict = schema[:strict] if strict.nil?

    refute additional
    assert strict
  end

  def test_tool_adapter_returns_no_runtime_context_when_not_bound
    tools = AgentLoop::AI::ToolAdapter.from_actions([LookupCustomer])
    response = tools.first.call({ 'email' => 'no-runtime@example.com' })

    refute response[:queued]
    assert_equal 'no_runtime_context', response[:error]
  end

  def test_dispatcher_runs_deferred_calls_for_instance
    sink = AgentLoop::AI::InMemoryToolExecSink.new
    tools = AgentLoop::AI::ToolAdapter.from_actions([LookupCustomer])
    AgentLoop::AI::ToolAdapter.with_runtime(instance_id: 'tool-runtime-3', sink: sink) do
      tools.first.call({ 'email' => 'dispatch@example.com' })
    end

    tool_adapter = AgentLoop::Adapters::Tools::ActionRegistry.new(actions: [LookupCustomer])
    emit_adapter = AgentLoop::Adapters::Emitter::InProcess.new
    effect_executor = AgentLoop::Effects::Executor.new(emit_adapter: emit_adapter, tool_adapter: tool_adapter)
    runtime = AgentLoop::Runtime.new(effect_executor: effect_executor)
    instance = AgentLoop::Instance.new(agent_class: ToolRuntimeAgent, id: 'tool-runtime-3')

    dispatcher = AgentLoop::AI::ToolExecDispatcher.new(sink: sink)
    dispatcher.dispatch(instance: instance, runtime: runtime)

    assert_equal 0, sink.size(instance_id: 'tool-runtime-3')
    assert_equal 'lookup_customer', instance.state[:tool_action]
  end

  def test_schema_converter_handles_nested_arrays_enum_nullable_and_descriptions
    schema = ComplexSchemaAction.parameters_json_schema

    refute schema[:additionalProperties]
    assert schema[:strict]

    user = schema.dig(:properties, 'user')

    assert_equal 'object', user[:type]
    refute user[:additionalProperties]
    assert_equal 'Customer email', user.dig(:properties, 'email', :description)

    tags = schema.dig(:properties, 'tags')

    assert_equal 'array', tags[:type]
    assert_equal 'string', tags.dig(:items, :type)

    status = schema.dig(:properties, 'status')

    assert_equal %w[pending active], status[:enum]
    assert_equal 'Lifecycle status', status[:description]

    nickname = schema.dig(:properties, 'nickname')

    assert_equal %w[string null], nickname[:type]
  end

  def test_action_registry_rejects_tool_actions_that_return_effects
    tool_adapter = AgentLoop::Adapters::Tools::ActionRegistry.new(actions: [EffectfulToolAction])
    emit_adapter = AgentLoop::Adapters::Emitter::InProcess.new
    effect_executor = AgentLoop::Effects::Executor.new(emit_adapter: emit_adapter, tool_adapter: tool_adapter)
    runtime = AgentLoop::Runtime.new(effect_executor: effect_executor)
    instance = AgentLoop::Instance.new(agent_class: ToolRuntimeAgent, id: 'tool-runtime-2')

    assert_raises(AgentLoop::Adapters::Tools::ActionRegistry::ToolActionEffectsNotSupported) do
      tool_adapter.run(name: 'effectful_tool_action', input: { id: '123' }, instance: instance, runtime: runtime,
                       meta: {})
    end
  end
end
