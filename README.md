# AgentLoop

AgentLoop is a work-in-progress Ruby agent runtime.

It is inspired by [Jido](https://github.com/agentjido/jido), with a similar focus on:

- data-first agents
- explicit command boundaries
- clear separation between state transitions and side effects
- mailbox-backed `AgentServer` runtime hosts
- delayed signals that replay back through runtime

The core model is:

- `AgentLoop::Agent` decides through `cmd`
- `AgentLoop::AgentServer` owns one live instance and processes signals serially
- `AgentLoop::Runtime` acts as the shared execution kernel
- `Effects::Schedule` uses your job backend for delayed replay
- `Effects::Spawn` starts real child servers

Quick start:

```ruby
server = AgentLoop::AgentServer.start(agent: CounterAgent)

server.call(
  AgentLoop::Signal.new(type: "counter.increment", source: "readme", data: { by: 1 })
)
```

This project is still evolving and APIs may change.

Start here:

- [Agent Runtime](https://github.com/TheZero0-ctrl/agent_loop/blob/main/docs/concepts/agent-runtime.md)
- [Sensors](https://github.com/TheZero0-ctrl/agent_loop/blob/main/docs/concepts/sensors.md)
- [First Agent](https://github.com/TheZero0-ctrl/agent_loop/blob/main/docs/getting-started/first-agent.md)

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

## Contributing

Bug reports and pull requests are welcome.
