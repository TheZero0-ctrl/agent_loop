# frozen_string_literal: true

require "test_helper"

class JidoStyleActionsTest < Minitest::Test
  class CounterAgent
    include AgentLoop::Agent

    name "counter_agent"
    description "Tracks a simple counter"

    schema defaults: { count: 0 } do
      required(:count).filled(:integer)
    end
  end

  class IncrementAction < AgentLoop::Action
    schema defaults: { by: 1 } do
      required(:by).filled(:integer)
    end

    output_schema do
      required(:count).filled(:integer)
    end

    def self.run(params, context)
      current = context.fetch(:state).fetch(:count)
      [
        { count: current + params.fetch(:by), passthrough: "ok" },
        [AgentLoop::Effects::Emit.new(type: "counter.updated")]
      ]
    end
  end

  class BrokenOutputAction < AgentLoop::Action
    output_schema do
      required(:count).filled(:integer)
    end

    def self.run(_params, _context)
      { count: "not_an_integer" }
    end
  end

  class ValidateOrder < AgentLoop::Action
    schema do
      required(:order_id).filled(:string)
    end

    def self.run(params, _context)
      { order_id: params.fetch(:order_id), validated: true }
    end
  end

  class ApplyDiscount < AgentLoop::Action
    schema do
      required(:validated).filled(:bool)
    end

    def self.run(params, _context)
      discount = params.fetch(:validated) ? 0.10 : 0.0
      { discount: discount }
    end
  end

  class ProcessOrder < AgentLoop::Action
    schema do
      required(:order_id).filled(:string)
    end

    def self.run(params, context)
      {
        order_id: params.fetch(:order_id),
        tenant_id: context[:tenant_id],
        timeout: context[:opts]&.first&.fetch(:timeout, nil)
      }
    end
  end

  def test_cmd_updates_agent_and_returns_directives
    agent = CounterAgent.new

    updated_agent, directives = CounterAgent.cmd(agent, [IncrementAction, { "by" => 3 }])

    assert_equal({ count: 0 }, agent.state)
    assert_equal 3, updated_agent.state[:count]
    assert_equal 1, directives.size
    assert_instance_of AgentLoop::Effects::Emit, directives.first
  end

  def test_cmd_returns_error_directive_for_invalid_action_params
    agent = CounterAgent.new

    same_agent, directives = CounterAgent.cmd(agent, [IncrementAction, { by: "bad" }])

    assert_equal({ count: 0 }, same_agent.state)
    assert_equal 1, directives.size
    assert_instance_of AgentLoop::Effects::Error, directives.first
    assert_equal :invalid_action_params, directives.first.code
  end

  def test_cmd_returns_error_directive_for_invalid_action_output
    agent = CounterAgent.new

    same_agent, directives = CounterAgent.cmd(agent, [BrokenOutputAction, {}])

    assert_equal({ count: 0 }, same_agent.state)
    assert_equal 1, directives.size
    assert_instance_of AgentLoop::Effects::Error, directives.first
    assert_equal :invalid_action_output, directives.first.code
  end

  def test_cmd_executes_action_chain_with_mixed_instruction_formats
    agent = CounterAgent.new

    updated_agent, directives = CounterAgent.cmd(agent, [
                                                   [ValidateOrder, { order_id: "ord_99" }],
                                                   ApplyDiscount
                                                 ])

    assert_equal "ord_99", updated_agent.state[:order_id]
    assert_equal true, updated_agent.state[:validated]
    assert_equal 0.10, updated_agent.state[:discount]
    assert_equal [], directives
  end

  def test_cmd_accepts_full_instruction_struct_with_context_and_opts
    agent = CounterAgent.new

    instruction = AgentLoop::Instruction.new!(
      action: ProcessOrder,
      params: { order_id: "ord_99" },
      context: { tenant_id: "tenant_456" },
      opts: [{ timeout: 10_000 }]
    )

    updated_agent, directives = CounterAgent.cmd(agent, instruction)

    assert_equal "ord_99", updated_agent.state[:order_id]
    assert_equal "tenant_456", updated_agent.state[:tenant_id]
    assert_equal 10_000, updated_agent.state[:timeout]
    assert_equal [], directives
  end
end
