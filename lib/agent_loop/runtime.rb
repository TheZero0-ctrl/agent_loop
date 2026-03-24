# frozen_string_literal: true

module AgentLoop
  class Runtime
    attr_reader :router, :effect_executor, :state_store, :state_op_applicator

    def initialize(effect_executor:, router: Router.new, state_store: AgentLoop::StateStores::InMemory.new,
                   state_op_applicator: AgentLoop::StateOps::Applicator.new)
      @router = router
      @effect_executor = effect_executor
      @state_store = state_store
      @state_op_applicator = state_op_applicator
    end

    def call(instance, signal, context: {})
      AgentLoop::Notifications.instrument("agent_loop.signal", instance_id: instance.id, signal_type: signal.type) do
        agent = instance.agent_class.new

        current_state = instance.state || state_store.load(instance.id) || agent.initial_state
        instruction = router.instruction_for(instance.agent_class, signal)

        result = agent.cmd(
          current_state,
          instruction,
          context: context.merge(instance_id: instance.id, signal: signal)
        )

        final_state = state_op_applicator.apply_all(result.state, result.state_ops)

        instance.state = final_state
        instance.status = :active
        state_store.save(instance.id, final_state)

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
  end
end
