# frozen_string_literal: true

module AgentLoop
  class Runtime
    attr_reader :router, :effect_executor, :state_store, :state_op_applicator, :strategy, :event_store

    def initialize(effect_executor:, router: Router.new, state_store: AgentLoop::StateStores::InMemory.new,
                   state_op_applicator: AgentLoop::StateOps::Applicator.new,
                   strategy: AgentLoop::Strategies::Direct.new,
                   event_store: AgentLoop::EventStores::InMemory.new)
      @router = router
      @effect_executor = effect_executor
      @state_store = state_store
      @state_op_applicator = state_op_applicator
      @strategy = strategy
      @event_store = event_store
    end

    def call(instance, signal, context: {})
      payload = notification_payload(instance, signal, context)

      AgentLoop::Notifications.instrument_lifecycle("agent_loop.signal", payload) do
        agent = instance.agent_class.new

        current_state = instance.state || state_store.load(instance.id) || agent.initial_state
        record_event(instance.id, type: "signal.received", signal: serialize_signal(signal), context: context)
        instruction = router.instruction_for(instance.agent_class, signal)

        result = AgentLoop::Notifications.instrument_lifecycle("agent_loop.cmd",
                                                               payload.merge(action: instruction.action)) do
          strategy.cmd(
            agent: agent,
            state: current_state,
            instruction: instruction,
            context: context.merge(instance_id: instance.id, signal: signal)
          )
        end

        final_state = state_op_applicator.apply_all(result.state, result.state_ops)

        instance.state = final_state
        instance.status = :active
        instance.metadata[:state_version] = instance.metadata.fetch(:state_version, 0) + 1
        state_store.save(instance.id, final_state)
        record_event(
          instance.id,
          type: "cmd.applied",
          action: instruction.action,
          state_version: instance.metadata[:state_version],
          status: result.status,
          effects: result.effects.map { |effect| effect.class.name }
        )

        effect_executor.execute_all(result.effects, instance: instance, runtime: self)

        Result.new(
          state: final_state,
          state_ops: result.state_ops,
          effects: result.effects,
          status: result.status,
          error: result.error
        )
      end
    rescue AgentLoop::Router::RouteNotFound => e
      raise AgentLoop::RuntimeError.new(e.message, code: :route_not_found,
                                                   context: { instance_id: instance.id, signal_type: signal.type })
    end

    private

    def record_event(instance_id, event)
      event_store&.append(instance_id, event)
    rescue StandardError
      nil
    end

    def serialize_signal(signal)
      {
        id: signal.id,
        type: signal.type,
        source: signal.source,
        subject: signal.subject,
        time: signal.time,
        metadata: signal.metadata,
        data: signal.data
      }
    end

    def notification_payload(instance, signal, context)
      {
        instance_id: instance.id,
        agent_class: instance.agent_class.to_s,
        signal_type: signal.type,
        trace_id: context[:trace_id] || signal.metadata[:trace_id]
      }
    end
  end
end
