# frozen_string_literal: true

module AgentLoop
  class Runtime
    attr_reader :router, :effect_executor, :state_store, :state_op_applicator,
                :strategy, :event_store, :signal_queue, :effect_queue

    def initialize(effect_executor:, router: Router.new, state_store: AgentLoop::StateStores::InMemory.new,
                   state_op_applicator: AgentLoop::StateOps::Applicator.new,
                   strategy: AgentLoop::Strategies::Direct.new,
                   event_store: AgentLoop::EventStores::InMemory.new,
                   signal_queue: AgentLoop::SignalQueues::InMemory.new,
                   effect_queue: AgentLoop::EffectQueues::InMemory.new)
      @router = router
      @effect_executor = effect_executor
      @state_store = state_store
      @state_op_applicator = state_op_applicator
      @strategy = strategy
      @event_store = event_store
      @signal_queue = signal_queue
      @effect_queue = effect_queue
    end

    def call(instance, signal, context: {})
      result = process_signal(instance, signal, context: context)
      effect_failures = execute_effects(result.effects, instance: instance, context: context)
      finalize_result(result, effect_failures)
    end

    def process_signal(instance, signal, context: {})
      payload = notification_payload(instance, signal, context)

      AgentLoop::Notifications.instrument_lifecycle('agent_loop.signal', payload) do
        agent = instance.agent_class.new
        strategy.init(agent_class: instance.agent_class, context: context) if strategy.respond_to?(:init)

        routed_signal = if instance.agent_class.respond_to?(:handle_signal_with_plugins)
                          instance.agent_class.handle_signal_with_plugins(signal, context: context)
                        else
                          signal
                        end

        current_state = instance.state || state_store.load(instance.id) || agent.initial_state
        track_signal_context(instance, routed_signal, context)
        record_event(instance.id, type: 'signal.received', signal: serialize_signal(routed_signal), context: context)
        instruction = router.instruction_for(instance.agent_class, routed_signal, strategy: strategy, context: context)

        result = AgentLoop::Notifications.instrument_lifecycle('agent_loop.cmd',
                                                               payload.merge(action: instruction.action)) do
          execute_cmd(agent: agent, current_state: current_state, instruction: instruction,
                      signal: routed_signal, instance: instance, context: context)
        end

        result = transform_result_with_plugins(instance.agent_class, result, instruction: instruction, context: context)

        final_state = if result.ok?
                        state_op_applicator.apply_all(result.state, result.state_ops)
                      else
                        current_state
                      end

        instance.state = final_state
        instance.status = derive_instance_status(result, final_state)
        increment_state_version(instance) if result.ok?
        state_store.save(instance.id, final_state)
        record_event(
          instance.id,
          type: 'cmd.applied',
          action: instruction.action,
          state_version: instance.metadata[:state_version],
          status: result.status,
          effects: result.effects.map { |effect| effect.class.name }
        )

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

    def execute_effects(effects, instance:, context: {})
      failures = []

      Array(effects).each do |effect|
        failure = execute_effect(effect, instance: instance, context: context)
        failures << failure if failure
      end

      failures
    end

    def finalize_result(result, effect_failures)
      final_status, final_error = finalize_runtime_outcome(result, effect_failures)

      Result.new(
        state: result.state,
        state_ops: result.state_ops,
        effects: result.effects,
        status: final_status,
        error: final_error
      )
    end

    def cast(instance, signal, context: {})
      signal_queue.enqueue(instance: instance, signal: signal, context: context)
      :ok
    end

    def drain(limit: nil)
      signal_queue.drain(runtime: self, limit: limit) do |entry|
        call(entry.fetch(:instance), entry.fetch(:signal), context: entry.fetch(:context, {}))
      end
    end

    def tick(instance, context: {})
      return :noop unless strategy.respond_to?(:tick)

      strategy.tick(instance: instance, runtime: self, context: context)
    end

    def snapshot(instance)
      return { instance_id: instance.id, strategy: strategy.class.name } unless strategy.respond_to?(:snapshot)

      strategy.snapshot(instance: instance)
    end

    private

    def record_event(instance_id, event)
      event_store&.append(instance_id, event)
    rescue StandardError
      nil
    end

    def execute_cmd(agent:, current_state:, instruction:, signal:, instance:, context: {})
      strategy.cmd(
        agent: agent,
        state: current_state,
        instruction: instruction,
        context: context.merge(instance_id: instance.id, signal: signal)
      )
    rescue StandardError => e
      error_result(current_state, e)
    end

    def transform_result_with_plugins(agent_class, result, instruction:, context: {})
      return result unless agent_class.respond_to?(:transform_result_with_plugins)

      agent_class.transform_result_with_plugins(result, instruction: instruction, context: context)
    rescue StandardError
      result
    end

    def error_result(state, error)
      code, details = classify_error(error)
      Result.new(
        state: state,
        state_ops: [],
        effects: [AgentLoop::Effects::Error.new(code: code, message: error.message, details: details)],
        status: :error,
        error: { code: code, message: error.message, details: details }
      )
    end

    def classify_error(error)
      case error
      when AgentLoop::Action::InvalidParams
        [:invalid_action_params, error.details]
      when AgentLoop::Action::InvalidOutput
        [:invalid_action_output, error.details]
      when AgentLoop::Agent::InvalidState
        [:invalid_state, error.details]
      when AgentLoop::Strategies::Fsm::InvalidTransition
        [:invalid_transition, {}]
      else
        [:runtime_execution_failed, {}]
      end
    end

    def increment_state_version(instance)
      instance.metadata[:state_version] = instance.metadata.fetch(:state_version, 0) + 1
    end

    def derive_instance_status(result, state)
      return :failed unless result.ok?

      state_lifecycle_status(state) || :active
    end

    def state_lifecycle_status(state)
      return unless state.is_a?(Hash)

      raw = state[:status] || state['status']
      status = raw&.to_sym
      return status if %i[completed failed stopped].include?(status)

      nil
    end

    def execute_effect(effect, instance:, context: {})
      if effect_executor.respond_to?(:execute)
        effect_executor.execute(effect, instance: instance, runtime: self)
      else
        effect_executor.execute_all([effect], instance: instance, runtime: self)
      end
      nil
    rescue StandardError => e
      record_event(
        instance.id,
        type: 'effect.failed',
        effect: effect.class.name,
        error_class: e.class.name,
        error_message: e.message,
        context: context
      )
      instance.status = :failed
      failure = {
        code: :effect_execution_failed,
        message: e.message,
        effect: effect.class.name,
        error_class: e.class.name,
        context: context
      }
      instance.metadata[:last_error] = { code: failure[:code], message: failure[:message] }
      failure
    end

    def finalize_runtime_outcome(result, effect_failures)
      return [result.status, result.error] if effect_failures.empty?

      failure = effect_failures.first
      [:error, failure]
    end

    def serialize_signal(signal)
      {
        specversion: signal.specversion,
        id: signal.id,
        type: signal.type,
        source: signal.source,
        subject: signal.subject,
        time: signal.time,
        datacontenttype: signal.datacontenttype,
        dataschema: signal.dataschema,
        metadata: signal.metadata,
        data: signal.data
      }
    end

    def track_signal_context(instance, signal, context)
      instance.metadata[:last_signal_id] = signal.id
      instance.metadata[:trace_id] = context[:trace_id] || signal.metadata[:trace_id]
      instance.metadata[:correlation_id] = context[:correlation_id] || signal.metadata[:correlation_id]
      instance.metadata[:causation_id] = context[:causation_id] || signal.metadata[:causation_id]
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
