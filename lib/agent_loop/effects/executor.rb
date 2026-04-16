# frozen_string_literal: true

module AgentLoop
  module Effects
    class Executor
      class UnsupportedEffect < StandardError; end

      def initialize(emit_adapter:, scheduled_signal_job_class: nil,
                     tool_adapter: AgentLoop::Adapters::Tools::AgentStrategyRegistry.new,
                     server_manager: AgentLoop::ServerManager.new)
        @emit_adapter = emit_adapter
        @scheduled_signal_job_class = scheduled_signal_job_class
        @tool_adapter = tool_adapter
        @server_manager = server_manager
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
            enqueue_scheduled_signal(effect, instance: instance)
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
              metadata: {
                parent_id: instance.id,
                parent_tag: effect.tag,
                on_parent_death: effect.on_parent_death
              }
            )
            child_server = @server_manager.start(runtime: runtime, instance: child)
            instance.children[effect.tag] = {
              id: child.id,
              server: child_server,
              on_parent_death: effect.on_parent_death,
              status: :started
            }
            emit_child_signal('agent_loop.child.started', instance: instance, child: child, tag: effect.tag)
            notify_live_parent(instance.id,
                               child_signal('agent_loop.child.started', instance: instance, child: child,
                                                                        tag: effect.tag))
            :ok
          when AgentLoop::Effects::RunTool
            run_tool_effect(effect, instance: instance, runtime: runtime)
          else
            raise UnsupportedEffect, "Unsupported effect: #{effect.class}"
          end
        end
      end

      private

      def enqueue_scheduled_signal(effect, instance:)
        job_class = @scheduled_signal_job_class
        raise UnsupportedEffect, 'Schedule requires a configured job class' unless job_class

        payload = {
          'instance_id' => instance.id,
          'agent_class' => instance.agent_class.to_s,
          'signal' => effect.signal.to_h,
          'meta' => effect.meta
        }

        job = job_class
        job = job.set(wait: effect.delay_ms.to_f / 1000.0) if effect.delay_ms && job.respond_to?(:set)
        return job.perform_later(payload) if job.respond_to?(:perform_later)

        raise UnsupportedEffect, "Scheduled job class must support perform_later: #{job_class}"
      end

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

      def emit_child_signal(type, instance:, child:, tag:)
        signal = child_signal(type, instance: instance, child: child, tag: tag)

        @emit_adapter.emit(signal, target: instance.id)
      end

      def child_signal(type, instance:, child:, tag:)
        AgentLoop::Signal.new(
          type: type,
          source: "agent://#{instance.id}",
          data: {
            parent_id: instance.id,
            child_id: child.id,
            child_class: child.agent_class.to_s,
            tag: tag
          }
        )
      end

      def notify_live_parent(parent_id, signal)
        parent_server = @server_manager.whereis(parent_id)
        return unless parent_server
        return unless parent_server.accepts_signal?(signal)

        parent_server.cast(signal)
      end
    end
  end
end
