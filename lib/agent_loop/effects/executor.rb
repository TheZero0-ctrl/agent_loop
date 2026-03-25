# frozen_string_literal: true

module AgentLoop
  module Effects
    class Executor
      class UnsupportedEffect < StandardError; end

      def initialize(emit_adapter:, scheduler_adapter: AgentLoop::Adapters::Scheduler::Inline.new,
                     tool_adapter: AgentLoop::Adapters::Tools::Null.new)
        @emit_adapter = emit_adapter
        @scheduler_adapter = scheduler_adapter
        @tool_adapter = tool_adapter
      end

      def execute_all(effects, instance:, runtime:)
        Array(effects).each do |effect|
          execute(effect, instance: instance, runtime: runtime)
        end
      end

      def execute(effect, instance:, runtime:)
        payload = {
          instance_id: instance.id,
          agent_class: instance.agent_class.to_s,
          effect_type: effect.class.name
        }

        AgentLoop::Notifications.instrument_lifecycle('agent_loop.effect', payload) do
          case effect
          when AgentLoop::Effects::Emit
            signal = effect.to_signal(
              default_source: "agent://#{instance.id}",
              default_metadata: {
                trace_id: instance.metadata[:trace_id],
                correlation_id: instance.metadata[:correlation_id],
                causation_id: instance.metadata[:last_signal_id]
              }
            )
            @emit_adapter.emit(signal, target: effect.target)
          when AgentLoop::Effects::Schedule
            @scheduler_adapter.schedule(delay_ms: effect.delay_ms) do
              runtime.call(instance, effect.signal)
            end
          when AgentLoop::Effects::Stop
            instance.status = :stopped
            instance.metadata[:stop_reason] = effect.reason
            :ok
          when AgentLoop::Effects::Error
            instance.status = :failed
            instance.metadata[:last_error] = {
              code: effect.code,
              message: effect.message,
              details: effect.details
            }
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
            emit_child_signal('agent_loop.child.started', instance: instance, child: child)
            :ok
          when AgentLoop::Effects::RunTool
            run_tool_effect(effect, instance: instance, runtime: runtime)
          else
            raise UnsupportedEffect, "Unsupported effect: #{effect.class}"
          end
        end
      end

      private

      def run_tool_effect(effect, instance:, runtime:)
        output = @tool_adapter.run(name: effect.name, input: effect.input, instance: instance, runtime: runtime,
                                   meta: effect.meta)
        callback_event = effect.callback_event
        return output unless callback_event

        signal = build_callback_signal(callback_event, instance: instance, tool_name: effect.name, output: output,
                                                       meta: effect.meta)
        runtime.call(instance, signal)
        output
      end

      def build_callback_signal(callback_event, instance:, tool_name:, output:, meta: {})
        metadata = {
          causation_id: instance.id,
          tool_call_id: meta[:tool_call_id],
          trace_id: meta[:trace_id],
          correlation_id: meta[:correlation_id]
        }.compact

        payload = {
          'result' => output,
          'tool_call_id' => meta[:tool_call_id],
          'tool_name' => tool_name,
          'action_class' => meta[:action_class],
          'action_ref' => meta[:action_ref],
          'requested_at' => meta[:requested_at]
        }.compact

        case callback_event
        when String, Symbol
          AgentLoop::Signal.new(
            type: callback_event.to_s,
            source: "tool://#{tool_name}",
            data: payload,
            metadata: metadata
          )
        when Hash
          AgentLoop::Signal.new(
            type: callback_event.fetch(:type).to_s,
            source: callback_event.fetch(:source, "tool://#{tool_name}"),
            data: callback_event.fetch(:data, {}).merge(payload),
            metadata: metadata.merge(callback_event.fetch(:metadata, {}))
          )
        else
          raise UnsupportedEffect, "Unsupported callback event descriptor: #{callback_event.inspect}"
        end
      end

      def emit_child_signal(type, instance:, child:)
        signal = AgentLoop::Signal.new(
          type: type,
          source: "agent://#{instance.id}",
          data: {
            parent_id: instance.id,
            child_id: child.id,
            child_class: child.agent_class.to_s
          }
        )

        @emit_adapter.emit(signal, target: instance.id)
      end
    end
  end
end
