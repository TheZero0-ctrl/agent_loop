# frozen_string_literal: true

require 'test_helper'

class AIAgentApiTest < Minitest::Test
  class LookupCustomerTool < AgentLoop::Action
    name 'lookup_customer'

    schema do
      required(:email).filled(:string)
    end

    def self.run(params, _context)
      { found: true, customer: { email: params.fetch(:email), plan: 'pro' } }
    end
  end

  class SupportAIAgent
    include AgentLoop::AI::Agent

    react tools: [LookupCustomerTool],
          entry_signals: ['support.ask'],
          tick_delay_ms: 1
  end

  class FakeRubyLLMMessage
    attr_reader :content

    def initialize(content)
      @content = content
    end
  end

  class FakeRubyLLMChat
    def initialize
      @calls = 0
    end

    def with_tools(*tools, calls: nil)
      @tools = tools
      @calls_mode = calls
      self
    end

    def ask(_prompt)
      @calls += 1

      if @calls == 1
        @tools.first.call({ 'email' => 'jane@example.com' })
        FakeRubyLLMMessage.new('')
      else
        FakeRubyLLMMessage.new('Customer is active on Pro plan.')
      end
    end
  end

  class InlineScheduleJob
    class << self
      attr_accessor :runtime
    end

    def self.perform_later(payload)
      AgentLoop::AgentServer.deliver_scheduled_signal(payload: payload, runtime: runtime)
      :ok
    end
  end

  def with_fake_rubyllm
    original = Object.const_defined?(:RubyLLM) ? RubyLLM : nil
    shared_chat = FakeRubyLLMChat.new
    fake_module = Module.new
    fake_module.const_set(:Tool, RubyLLM::Tool)
    fake_module.singleton_class.class_eval do
      define_method(:chat) do |model: nil|
        _model = model
        shared_chat
      end
    end

    Object.send(:remove_const, :RubyLLM) if Object.const_defined?(:RubyLLM)
    Object.const_set(:RubyLLM, fake_module)
    yield
  ensure
    Object.send(:remove_const, :RubyLLM) if Object.const_defined?(:RubyLLM)
    Object.const_set(:RubyLLM, original) if original
  end

  def test_ask_and_await_helpers_complete_react_request
    with_fake_rubyllm do
      runtime = AgentLoop::Runtime.new(
        effect_executor: AgentLoop::Effects::Executor.new(
          emit_adapter: AgentLoop::Adapters::Emitter::Null.new,
          scheduled_signal_job_class: InlineScheduleJob
        ),
        state_store: AgentLoop::StateStores::InMemory.new
      )
      InlineScheduleJob.runtime = runtime

      request = SupportAIAgent.ask_async(
        prompt: 'check customer',
        data: { email: 'jane@example.com' },
        runtime: runtime,
        id: 'ai-agent-api-1',
        signal_type: 'support.ask'
      )
      result = SupportAIAgent.await(request, timeout: 2, poll_interval: 0.01)

      assert(result[:ok])
      assert_equal :success, result[:status]
      assert_equal 'Customer is active on Pro plan.', result[:answer]
      assert_equal request.id, result[:request_id]
      refute_empty result[:tool_calls]
    ensure
      SupportAIAgent.stop_server(id: 'ai-agent-api-1')
    end
  end

  def test_ask_returns_terminal_state_directly
    with_fake_rubyllm do
      runtime = AgentLoop::Runtime.new(
        effect_executor: AgentLoop::Effects::Executor.new(
          emit_adapter: AgentLoop::Adapters::Emitter::Null.new,
          scheduled_signal_job_class: InlineScheduleJob
        ),
        state_store: AgentLoop::StateStores::InMemory.new
      )
      InlineScheduleJob.runtime = runtime

      result = SupportAIAgent.ask(
        prompt: 'check customer',
        data: { email: 'jane@example.com' },
        runtime: runtime,
        id: 'ai-agent-api-2',
        signal_type: 'support.ask',
        timeout: 2,
        poll_interval: 0.01
      )

      assert(result[:ok])
      assert_equal :success, result[:status]
      assert_equal 'Customer is active on Pro plan.', result[:answer]
    ensure
      SupportAIAgent.stop_server(id: 'ai-agent-api-2')
    end
  end

  def test_ask_sync_alias_matches_ask
    with_fake_rubyllm do
      runtime = AgentLoop::Runtime.new(
        effect_executor: AgentLoop::Effects::Executor.new(
          emit_adapter: AgentLoop::Adapters::Emitter::Null.new,
          scheduled_signal_job_class: InlineScheduleJob
        ),
        state_store: AgentLoop::StateStores::InMemory.new
      )
      InlineScheduleJob.runtime = runtime

      result = SupportAIAgent.ask_sync(
        prompt: 'check customer',
        runtime: runtime,
        id: 'ai-agent-api-6',
        signal_type: 'support.ask',
        timeout: 2,
        poll_interval: 0.01
      )

      assert(result[:ok])
      assert_equal :success, result[:status]
      assert_equal result[:result], result[:answer]
    ensure
      SupportAIAgent.stop_server(id: 'ai-agent-api-6')
    end
  end

  def test_server_helper_returns_same_running_server
    runtime = AgentLoop::Runtime.new(
      effect_executor: AgentLoop::Effects::Executor.new(
        emit_adapter: AgentLoop::Adapters::Emitter::Null.new,
        scheduled_signal_job_class: Class.new do
          def self.perform_later(_payload)
            :ok
          end
        end
      ),
      state_store: AgentLoop::StateStores::InMemory.new
    )

    first = SupportAIAgent.server(runtime: runtime, id: 'ai-agent-api-3')
    second = SupportAIAgent.server(runtime: runtime, id: 'ai-agent-api-3')

    assert_same first, second
  ensure
    SupportAIAgent.stop_server(id: 'ai-agent-api-3')
  end

  def test_ask_async_uses_scheduled_continuation_when_needed
    with_fake_rubyllm do
      runtime = AgentLoop::Runtime.new(
        effect_executor: AgentLoop::Effects::Executor.new(
          emit_adapter: AgentLoop::Adapters::Emitter::Null.new,
          scheduled_signal_job_class: InlineScheduleJob
        ),
        state_store: AgentLoop::StateStores::InMemory.new
      )
      InlineScheduleJob.runtime = runtime

      request = SupportAIAgent.ask_async(
        prompt: 'check customer',
        data: { email: 'jane@example.com' },
        runtime: runtime,
        id: 'ai-agent-api-5',
        signal_type: 'support.ask'
      )

      assert_instance_of AgentLoop::AI::Agent::Request, request
      final = SupportAIAgent.await(request, timeout: 2, poll_interval: 0.01)

      assert(final[:ok])
    ensure
      SupportAIAgent.stop_server(id: 'ai-agent-api-5')
    end
  end

  def test_tool_activity_helper_returns_completed_calls
    with_fake_rubyllm do
      runtime = AgentLoop::Runtime.new(
        effect_executor: AgentLoop::Effects::Executor.new(
          emit_adapter: AgentLoop::Adapters::Emitter::Null.new,
          scheduled_signal_job_class: InlineScheduleJob
        ),
        state_store: AgentLoop::StateStores::InMemory.new
      )
      InlineScheduleJob.runtime = runtime

      SupportAIAgent.ask(
        prompt: 'check customer',
        data: { email: 'jane@example.com' },
        runtime: runtime,
        id: 'ai-agent-api-4',
        signal_type: 'support.ask',
        timeout: 2,
        poll_interval: 0.01
      )

      calls = SupportAIAgent.tool_activity(runtime: runtime, id: 'ai-agent-api-4')

      assert_equal :completed, calls.first[:status]
      assert_equal 'lookup_customer', calls.first[:name]
    ensure
      SupportAIAgent.stop_server(id: 'ai-agent-api-4')
    end
  end
end
