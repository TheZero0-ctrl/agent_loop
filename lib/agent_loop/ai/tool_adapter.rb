# frozen_string_literal: true

module AgentLoop
  module AI
    class ToolAdapter
      class RubyLLMMissing < StandardError; end

      class << self
        def from_actions(actions, strict: nil)
          ensure_rubyllm_tool!

          Array(actions).map do |action_class|
            build_rubyllm_tool(action_class, strict: strict_mode?(action_class, strict))
          end
        end

        def with_runtime(instance_id:, sink: default_sink, callback_event: 'tool.completed', context: {},
                         context_provider: nil)
          previous = current_runtime
          configure_runtime(
            instance_id: instance_id,
            sink: sink,
            callback_event: callback_event,
            context: context,
            context_provider: context_provider
          )
          yield
        ensure
          write_current_runtime(previous)
        end

        def configure_runtime(instance_id:, sink: default_sink, callback_event: 'tool.completed', context: {},
                              context_provider: nil)
          write_current_runtime(
            instance_id: instance_id,
            sink: sink,
            callback_event: callback_event,
            context: context,
            context_provider: context_provider
          )
        end

        def clear_runtime!
          write_current_runtime(nil)
        end

        def current_runtime
          Thread.current[:agent_loop_tool_runtime]
        end

        def run_deferred!(runtime:, instance:, sink: default_sink, limit: nil)
          sink.dequeue(instance_id: instance.id, limit: limit).each do |request|
            effect = AgentLoop::Effects::RunTool.new(
              name: request.tool_name,
              input: request.arguments,
              callback_event: request.callback_event,
              meta: {
                tool_call_id: request.id,
                action_class: request.action_class.name,
                action_ref: request.action_ref,
                trace_id: request.trace_id,
                correlation_id: request.correlation_id,
                causation_id: request.causation_id,
                requested_at: request.requested_at,
                context: request.context
              }
            )
            runtime.effect_executor.execute(effect, instance: instance, runtime: runtime)
          end
        end

        def run_collected!(collector:, runtime:, instance:, limit: nil)
          run_deferred!(sink: collector, runtime: runtime, instance: instance, limit: limit)
        end

        def capture_tool_call(action_class:, tool_name:, action_ref:, arguments:)
          runtime = current_runtime
          unless runtime
            return {
              queued: false,
              tool: tool_name,
              action_ref: action_ref,
              error: 'no_runtime_context',
              note: 'Configure AgentLoop::AI::ToolAdapter runtime before chat.ask'
            }
          end

          tool_context = runtime[:context_provider] ? runtime[:context_provider].call : runtime[:context]
          tool_context = {} unless tool_context.is_a?(Hash)

          request = AgentLoop::AI::ToolExecRequest.new(
            tool_name: tool_name,
            arguments: arguments,
            action_class: action_class,
            instance_id: runtime[:instance_id],
            callback_event: runtime[:callback_event],
            trace_id: tool_context[:trace_id],
            correlation_id: tool_context[:correlation_id],
            causation_id: tool_context[:causation_id],
            context: tool_context,
            action_ref: action_ref
          )
          runtime[:sink].enqueue(request)

          {
            queued: true,
            tool_call_id: request.id,
            tool: request.tool_name,
            action_ref: request.action_ref,
            instance_id: request.instance_id,
            callback_event: request.callback_event,
            note: 'Tool execution deferred to AgentLoop runtime'
          }
        end

        private

        def build_rubyllm_tool(action_class, strict:)
          descriptor = action_class.to_tool(strict: strict)
          name = descriptor.fetch(:name)
          description = descriptor.fetch(:description)
          parameters = descriptor.fetch(:parameters)
          action_ref = "#{action_class.name}@v1"

          klass = Class.new(::RubyLLM::Tool) do
            description(description)
            params(parameters)

            define_method(:name) { name }

            define_method(:execute) do |**kwargs|
              AgentLoop::AI::ToolAdapter.capture_tool_call(
                action_class: action_class,
                tool_name: name,
                action_ref: action_ref,
                arguments: kwargs
              )
            end
          end

          klass.new
        end

        def strict_mode?(action_class, strict)
          return action_class.strict? if strict.nil?

          strict == true
        end

        def ensure_rubyllm_tool!
          return if defined?(::RubyLLM::Tool)

          raise RubyLLMMissing, 'RubyLLM::Tool is not available. Add the ruby_llm gem to use ToolAdapter.'
        end

        def default_sink
          @default_sink ||= InMemoryToolExecSink.new
        end

        def write_current_runtime(runtime)
          Thread.current[:agent_loop_tool_runtime] = runtime
        end
      end
    end
  end
end
