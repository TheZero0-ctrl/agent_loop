# frozen_string_literal: true

require 'test_helper'

class BehaviorTreeAndReactStrategyTest < Minitest::Test
  class SetReady < AgentLoop::Action
    def self.run(_params, _context)
      { ready: true }
    end
  end

  class ReportStatus < AgentLoop::Action
    def self.run(_params, _context)
      { reported: true }
    end
  end

  class TreeAgent
    include AgentLoop::Agent

    default_state({ ready: false, reported: false })
    route 'tree.ready', to: SetReady
  end

  class ReactAgent
    include AgentLoop::Agent

    default_state({})
  end

  class LookupCustomerAction < AgentLoop::Action
    name 'lookup_customer'

    schema do
      required(:email).filled(:string)
    end

    def self.run(_params, _context)
      { found: true }
    end
  end

  class EntrySignalAgent
    include AgentLoop::Agent

    strategy AgentLoop::Strategies::React,
             tools: [],
             tick_delay_ms: 1
  end

  class FakeRubyLLMMessage
    attr_reader :content

    def initialize(content)
      @content = content
    end
  end

  class FakeRubyLLMChat
    def initialize(mode)
      @mode = mode
      @calls = 0
    end

    def with_tools(*tools, calls: nil)
      @tools = tools
      @calls_mode = calls
      self
    end

    def ask(_prompt)
      @calls += 1
      case @mode
      when :entry_final
        FakeRubyLLMMessage.new('handled_by_strategy_entry_signal')
      when :always_continue
        FakeRubyLLMMessage.new('')
      else
        if @calls == 1
          @tools.first.call({ 'email' => 'jane@example.com' })
          FakeRubyLLMMessage.new('')
        else
          FakeRubyLLMMessage.new('tool_complete')
        end
      end
    end
  end

  def with_fake_rubyllm(mode: :normal)
    original = Object.const_defined?(:RubyLLM) ? RubyLLM : nil
    shared_chat = FakeRubyLLMChat.new(mode)
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

  def test_behavior_tree_running_then_resume_to_success
    tree = AgentLoop::BehaviorTree.sequence([
                                              AgentLoop::BehaviorTree.condition(lambda { |state:, context:|
                                                _context = context
                                                state[:ready] ? true : :running
                                              }),
                                              AgentLoop::BehaviorTree.action(ReportStatus)
                                            ])

    strategy = AgentLoop::Strategies::BehaviorTree.new(tree: tree, tick_delay_ms: 10)
    agent = TreeAgent.new

    first = strategy.cmd(agent: agent, state: agent.state, instructions: [], context: {})

    assert_equal :ok, first.status
    assert(first.effects.any?(AgentLoop::Effects::Schedule))

    second = strategy.cmd(
      agent: agent,
      state: first.state,
      instructions: [AgentLoop::Instruction.new(action: SetReady, params: {})],
      context: {}
    )

    assert_equal :ok, second.status
    assert(second.state[:reported])
  end

  def test_react_strategy_supports_tick_and_tool_result_turns
    with_fake_rubyllm(mode: :normal) do
      strategy = AgentLoop::Strategies::React.new(
        tools: [LookupCustomerAction],
        tick_delay_ms: 10
      )
      agent = ReactAgent.new
      base_state = agent.state

      initial = strategy.cmd(
        agent: agent,
        state: base_state,
        instructions: [
          AgentLoop::Instruction.new(
            action: AgentLoop::Strategies::React::QUERY_ACTION,
            params: { prompt: 'lookup jane' }
          )
        ],
        context: {}
      )

      assert_equal :ok, initial.status
      initial_tool_effect = initial.effects.find { |effect| effect.is_a?(AgentLoop::Effects::RunTool) }

      refute_nil initial_tool_effect
      assert_equal 'agent_loop.strategy.react.tool_result', initial_tool_effect.callback_event

      tool_result = strategy.cmd(
        agent: agent,
        state: AgentLoop::StateOps::Applicator.new.apply_all(initial.state, initial.state_ops),
        instructions: [
          AgentLoop::Instruction.new(
            action: AgentLoop::Strategies::React::TOOL_RESULT_ACTION,
            params: { tool_call_id: initial_tool_effect.meta[:tool_call_id], result: { customer_id: 'cus_1' } }
          )
        ],
        context: {}
      )

      assert_equal :ok, tool_result.status
      final_state = AgentLoop::StateOps::Applicator.new.apply_all(tool_result.state, tool_result.state_ops)
      strategy_state = final_state.dig(:__strategy__, :reasoning_loop)

      assert_equal :success, strategy_state[:status]
      assert_equal 'tool_complete', strategy_state[:result]
    end
  end

  def test_react_strategy_with_empty_response_fails_fast
    with_fake_rubyllm(mode: :always_continue) do
      strategy = AgentLoop::Strategies::React.new(
        tools: [],
        continuation_mode: :scheduled,
        tick_delay_ms: 10
      )

      result = strategy.cmd(
        agent: ReactAgent.new,
        state: {},
        instructions: [AgentLoop::Instruction.new(action: AgentLoop::Strategies::React::QUERY_ACTION, params: {})],
        context: {}
      )

      assert_equal :error, result.status
      assert_equal :react_failed, result.effects.first.code
    end
  end

  def test_react_strategy_handles_default_entry_signal_without_agent_route
    with_fake_rubyllm(mode: :entry_final) do
      runtime = AgentLoop::Runtime.new(
        strategy: AgentLoop::Strategies::Direct.new,
        effect_executor: AgentLoop::Effects::Executor.new(
          emit_adapter: AgentLoop::Adapters::Emitter::Null.new
        )
      )

      server = AgentLoop::AgentServer.start(agent: EntrySignalAgent, id: 'react-entry-1', runtime: runtime)
      signal = AgentLoop::Signal.new(type: 'ai.react.query', source: 'test', data: { prompt: 'hello' })
      result = server.call(signal)

      assert_equal :ok, result.status
      loop_state = server.state.dig(:__strategy__, :reasoning_loop)

      assert_equal :success, loop_state[:status]
      assert_equal 'handled_by_strategy_entry_signal', loop_state[:result]
    ensure
      server&.stop
    end
  end
end
