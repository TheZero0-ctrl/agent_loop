# Your first agent

Define typed state, implement a validated action, and run your first command.

## Setup

Install agent_loop gem

## Define the agent

An `AgentLoop::Agent` defines metadata and a typed state schema.

```ruby
class CounterAgent
  include AgentLoop::Agent

  name "counter_agent"
  description "Tracks a simple counter"
  schema defaults: { count: 0 } do
    required(:count).filled(:integer)
  end
end
```

`CounterAgent.new` now returns an agent value object with validated default state.

## Define an action

Actions are validated command objects.

```ruby
class IncrementAction < AgentLoop::Action
  name "increment"
  description "Increments the counter by a specified amount"
  schema defaults: { by: 1 } do
    required(:by).filled(:integer)
  end

  def self.run(params, context)
    current = context.fetch(:state).fetch(:count, 0)

    [
      { count: current + params.fetch(:by) },
      [
        AgentLoop::Effects::Emit.new(
          type: "counter.updated",
          data: { count: current + params.fetch(:by) }
        )
      ]
    ]
  end
end
```

## Create an agent and run a command

`CounterAgent.cmd` takes an agent value and an instruction tuple.

```ruby
agent = CounterAgent.new

updated_agent, effects = CounterAgent.cmd(agent, [IncrementAction, { "by" => 3 }], context: { trace_id: "trace-123" })
```

## Inspect the results

The original agent is unchanged. `updated_agent` has new state and `effects` carries runtime effect descriptors.

```ruby
agent.state
# => { count: 0 }

updated_agent.state
# => { count: 3 }

effects.map(&:class)
# => [AgentLoop::Effects::Emit]
```

## Handle validation errors

If params fail action schema validation, state stays unchanged and an `Effects::Error` effect is returned.

```ruby
same_agent, error_effects =
  CounterAgent.cmd(agent, [IncrementAction, { by: "not_a_number" }])

same_agent.state
# => { count: 0 }

error_effects.first.code
# => :invalid_action_params
```

## Run through runtime (signal-driven path)

Use runtime when you need routing, persistence, and effect execution.

```ruby
class CounterRuntimeAgent
  include AgentLoop::Agent

  default_state({ count: 0 })
  route "counter.increment", to: IncrementAction
end

emit_adapter = AgentLoop::Adapters::Emitter::InProcess.new
effect_executor = AgentLoop::Effects::Executor.new(emit_adapter: emit_adapter)
runtime = AgentLoop::Runtime.new(effect_executor: effect_executor)

instance = AgentLoop::Instance.new(agent_class: CounterRuntimeAgent, id: "counter-1")
signal = AgentLoop::Signal.new(type: "counter.increment", source: "docs", data: { "by" => 2 })

runtime.call(instance, signal)

instance.state
# => { count: 2 }

emit_adapter.events.map { |event| event[:signal].type }
# => ["counter.updated"]
```
