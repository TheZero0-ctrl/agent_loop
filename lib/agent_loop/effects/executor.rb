# frozen_string_literal: true

module AgentLoop
  module Effects
    class Executor
      class UnsupportedEffect < StandardError; end

      def initialize(emit_adapter:, scheduler_adapter: AgentLoop::Adapters::Scheduler::Inline.new)
        @emit_adapter = emit_adapter
        @scheduler_adapter = scheduler_adapter
      end

      def execute_all(effects, instance:, runtime:)
        Array(effects).each do |effect|
          execute(effect, instance: instance, runtime: runtime)
        end
      end

      def execute(effect, instance:, runtime:)
        AgentLoop::Notifications.instrument('agent_loop.effect', instance_id: instance.id,
                                                                 effect_type: effect.class.name) do
          case effect
          when AgentLoop::Effects::Emit
            signal = AgentLoop::Signal.new(type: effect.type, data: effect.data, source: "agent://#{instance.id}")
            @emit_adapter.emit(signal, target: effect.target)
          when AgentLoop::Effects::Schedule
            @scheduler_adapter.schedule(delay_ms: effect.delay_ms) do
              runtime.call(instance, effect.signal)
            end
          when AgentLoop::Effects::Stop
            instance.status = :stopped
            instance.metadata[:stop_reason] = effect.reason
            :ok
          when AgentLoop::Effects::Spawn
            child = AgentLoop::Instance.new(
              agent_class: effect.agent_class,
              id: effect.id,
              state: effect.initial_state,
              status: :idle,
              metadata: { parent_id: instance.id }
            )
            instance.children[effect.id] = child
            :ok
          when AgentLoop::Effects::RunTool
            # Stub behavior for MVP. Wire your tool adapter here.
            :ok
          else
            raise UnsupportedEffect, "Unsupported effect: #{effect.class}"
          end
        end
      end
    end
  end
end
