# frozen_string_literal: true

require 'test_helper'

class RubyLlmReactPlannerTest < Minitest::Test
  class LookupCustomerAction < AgentLoop::Action
    name 'lookup_customer'
    description 'Find customer account by email'

    schema do
      required(:email).filled(:string)
    end

    def self.run(_params, _context)
      { ok: true }
    end
  end

  class FakeRubyLLMMessage
    attr_reader :content

    def initialize(content)
      @content = content
    end
  end

  class FakeRubyLLMChat
    def initialize(mode)
      @calls = 0
      @mode = mode
    end

    def with_tools(*tools, calls: nil)
      @tools = tools
      @calls_mode = calls
      self
    end

    def ask(_prompt)
      @calls += 1
      if @mode == :invalid_tool
        runtime = AgentLoop::AI::ToolAdapter.current_runtime
        fake_request = AgentLoop::AI::ToolExecRequest.new(
          tool_name: 'unknown_tool',
          arguments: { bad: true },
          action_class: LookupCustomerAction,
          instance_id: runtime[:instance_id],
          callback_event: AgentLoop::Strategies::React::DEFAULT_TOOL_CALLBACK_SIGNAL
        )
        runtime[:sink].enqueue(fake_request)
        FakeRubyLLMMessage.new('')
      elsif @calls == 1
        @tools.first.call({ 'email' => 'jane@example.com' })
        FakeRubyLLMMessage.new('')
      else
        FakeRubyLLMMessage.new('Customer is active.')
      end
    end
  end

  def setup
    @original_rubyllm = Object.const_defined?(:RubyLLM) ? RubyLLM : nil
  end

  def teardown
    Object.send(:remove_const, :RubyLLM) if Object.const_defined?(:RubyLLM)
    Object.const_set(:RubyLLM, @original_rubyllm) if @original_rubyllm
  end

  def install_fake_rubyllm(mode: :normal)
    chat = FakeRubyLLMChat.new(mode)
    fake_module = Module.new
    fake_module.const_set(:Tool, RubyLLM::Tool)
    fake_module.singleton_class.class_eval do
      define_method(:chat) do |model: nil|
        _model = model
        chat
      end
    end

    Object.send(:remove_const, :RubyLLM) if Object.const_defined?(:RubyLLM)
    Object.const_set(:RubyLLM, fake_module)
  end

  def test_returns_failure_when_max_turns_exceeded
    install_fake_rubyllm(mode: :normal)
    planner = AgentLoop::AI::RubyLlmReactPlanner.new(actions: [LookupCustomerAction], max_turns: 2)

    decision = planner.next_step(state: { history: [{}, {}] }, context: {})

    assert_equal :failure, decision[:type]
    assert_equal 'reasoning_turn_limit_exceeded', decision[:message]
  end

  def test_native_tool_calling_path_returns_tool_then_final
    install_fake_rubyllm(mode: :normal)

    planner = AgentLoop::AI::RubyLlmReactPlanner.new(actions: [LookupCustomerAction])

    first = planner.next_step(
      state: { history: [{ kind: :input, params: { prompt: 'lookup jane@example.com' } }] },
      context: { instance_id: 'native-1' }
    )

    assert_equal :tool, first[:type]
    assert_equal 'lookup_customer', first[:name]

    second = planner.next_step(
      state: { history: [{ kind: :tool_result, payload: { result: { found: true } } }] },
      context: { instance_id: 'native-1' }
    )

    assert_equal :final, second[:type]
    assert_equal 'Customer is active.', second[:result]
  end

  def test_native_tool_calling_rejects_invalid_tool_name
    install_fake_rubyllm(mode: :invalid_tool)

    planner = AgentLoop::AI::RubyLlmReactPlanner.new(actions: [LookupCustomerAction])

    decision = planner.next_step(
      state: { history: [{ kind: :input, params: { prompt: 'lookup jane@example.com' } }] },
      context: { instance_id: 'native-2' }
    )

    assert_equal :failure, decision[:type]
    assert_equal 'invalid_tool_name', decision[:message]
  end
end
