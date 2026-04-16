# frozen_string_literal: true

require 'json'
require 'timeout'

module AgentLoop
  module AI
    class RubyLLMReactPlanner
      class RubyLLMMissing < StandardError; end

      DEFAULT_SYSTEM_PROMPT = <<~PROMPT
        You are a planning engine for a ReAct-style runtime.

        Return only JSON with one of these shapes:
        {"type":"tool","name":"tool_name","input":{}}
        {"type":"final","result":"string answer"}
        {"type":"continue"}

        Rules:
        - Prefer tool calls when external data is needed.
        - Use only tools listed in the provided tool catalog.
        - If there is a tool_result in history and enough data exists, return final.
        - Never return markdown.
      PROMPT

      def initialize(actions:, model: nil,
                     system_prompt: DEFAULT_SYSTEM_PROMPT, max_turns: 8, request_timeout_s: 30,
                     strict_tools: true)
        @actions = Array(actions)
        @model = model
        @system_prompt = system_prompt
        @max_turns = max_turns
        @request_timeout_s = request_timeout_s
        @strict_tools = strict_tools
        @tool_descriptors = @actions.map { |action| action.to_tool(strict: true) }
        @allowed_tool_names = @tool_descriptors.map { |desc| desc.fetch(:name).to_s }
      end

      def next_step(state:, context:)
        history = Array(state[:history])
        return failure('reasoning_turn_limit_exceeded', max_turns: @max_turns) if history.length >= @max_turns

        native_decision(state: state, context: context, history: history)
      rescue Timeout::Error
        failure('reasoning_timeout', timeout_seconds: @request_timeout_s)
      rescue StandardError => e
        failure('reasoning_error', error_class: e.class.name, error_message: e.message)
      end

      private

      def native_decision(state:, context:, history:)
        ensure_rubyllm!
        ensure_rubyllm_tooling!

        tools = AgentLoop::AI::ToolAdapter.from_actions(@actions, strict: @strict_tools)
        sink = AgentLoop::AI::InMemoryToolExecSink.new
        instance_id = context[:instance_id] || context['instance_id'] || 'react-runtime'
        callback_event = context[:tool_callback_signal] || context['tool_callback_signal'] ||
                         AgentLoop::Strategies::React::DEFAULT_TOOL_CALLBACK_SIGNAL

        prompt = build_prompt(state: state, context: context, history: history)
        response = nil

        AgentLoop::AI::ToolAdapter.with_runtime(
          instance_id: instance_id,
          sink: sink,
          callback_event: callback_event,
          context: context
        ) do
          Timeout.timeout(@request_timeout_s) do
            chat = @model ? RubyLLM.chat(model: @model) : RubyLLM.chat
            chat = chat.with_tools(*tools, calls: :one)
            response = chat.ask(prompt)
          end
        end

        request = sink.dequeue(instance_id: instance_id, limit: 1).first
        return final_from_response(response) unless request

        return failure('invalid_tool_name', tool: request.tool_name) unless valid_tool_name?(request.tool_name)

        {
          type: :tool,
          name: request.tool_name,
          input: request.arguments,
          tool_call_id: request.id,
          action_ref: request.action_ref,
          callback_event: request.callback_event
        }
      end

      def ensure_rubyllm!
        return if defined?(::RubyLLM)

        raise RubyLLMMissing, 'RubyLLM is not available. Add the ruby_llm gem to use RubyLlmReactPlanner.'
      end

      def ensure_rubyllm_tooling!
        return if defined?(::RubyLLM::Tool)

        raise RubyLLMMissing, 'RubyLLM::Tool is not available. Ensure ruby_llm tool support is loaded.'
      end

      def final_from_response(response)
        text = if response.respond_to?(:content)
                 response.content.to_s
               else
                 response.to_s
               end

        return failure('empty_final_response') if text.strip.empty?

        { type: :final, result: text }
      end

      def build_prompt(state:, context:, history:)
        signal = context[:signal]
        prompt_text = if signal.respond_to?(:data) && signal.data.is_a?(Hash)
                        signal.data[:prompt] || signal.data['prompt']
                      end
        payload = {
          strategy_state: {
            phase: state[:phase],
            pending_tool: state[:pending_tool]
          },
          signal: {
            type: signal.respond_to?(:type) ? signal.type : nil,
            data: signal.respond_to?(:data) ? signal.data : nil
          },
          history: history.last(12),
          tool_catalog: @tool_descriptors
        }

        <<~TEXT
          #{@system_prompt}

          User prompt:
          #{prompt_text}

          Respond naturally. Use tools when needed.

          Context:
          #{JSON.generate(payload)}
        TEXT
      end

      def valid_tool_name?(name)
        return true unless @strict_tools

        @allowed_tool_names.include?(name)
      end

      def failure(message, details = {}, **extra)
        normalized_details = details.is_a?(Hash) ? details : {}
        {
          type: :failure,
          message: message,
          details: normalized_details.merge(extra)
        }
      end
    end

    RubyLlmReactPlanner = RubyLLMReactPlanner
  end
end
