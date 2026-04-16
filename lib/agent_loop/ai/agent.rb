# frozen_string_literal: true

require 'securerandom'

module AgentLoop
  module AI
    module Agent
      TERMINAL_STATUSES = %i[success failure].freeze

      class Request
        attr_reader :id, :server, :signal_type, :created_at, :initial_result

        def initialize(id:, server:, signal_type:, created_at:, initial_result:)
          @id = id
          @server = server
          @signal_type = signal_type
          @created_at = created_at
          @initial_result = initial_result
        end
      end

      def self.included(base)
        base.include(AgentLoop::Agent)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def react(tools:, model: nil,
                  system_prompt: AgentLoop::AI::RubyLlmReactPlanner::DEFAULT_SYSTEM_PROMPT,
                  max_turns: 8, request_timeout_s: 30, tick_delay_ms: 25,
                  tool_callback_signal: AgentLoop::Strategies::React::DEFAULT_TOOL_CALLBACK_SIGNAL,
                  entry_signals: AgentLoop::Strategies::React::DEFAULT_ENTRY_SIGNALS,
                  strict_tools: true,
                  continuation_mode: AgentLoop::Strategies::React::DEFAULT_CONTINUATION_MODE)
          @react_entry_signal = Array(entry_signals).map(&:to_s).first

          strategy AgentLoop::Strategies::React,
                   tools: tools,
                   model: model,
                   system_prompt: system_prompt,
                   max_turns: max_turns,
                   request_timeout_s: request_timeout_s,
                   tick_delay_ms: tick_delay_ms,
                   tool_callback_signal: tool_callback_signal,
                   entry_signals: entry_signals,
                   strict_tools: strict_tools,
                   continuation_mode: continuation_mode
        end

        def react_entry_signal
          @react_entry_signal || AgentLoop::Strategies::React::DEFAULT_ENTRY_SIGNALS.first
        end

        def server_id(value = nil)
          @server_id = value.to_s unless value.nil?
          @server_id || default_server_id
        end

        def default_server_id
          @default_server_id ||= begin
            class_name = name.to_s
            normalized = class_name.gsub('::', '-').gsub(/([a-z\d])([A-Z])/, '\1-\2').downcase
            "#{normalized}-default"
          end
        end

        def whereis(id: server_id)
          AgentLoop::AgentServer.whereis(id)
        end

        def server(runtime: AgentLoop.runtime, id: server_id, initial_state: {})
          AgentLoop::AgentServer.fetch_or_start(
            agent: self,
            runtime: runtime,
            id: id,
            initial_state: initial_state
          )
        end

        alias start server

        def stop_server(id: server_id)
          running = whereis(id: id)
          return :ok unless running

          running.stop(reason: :manual_stop)
        end

        def ask_async(prompt:, data: {}, source: 'agent_loop://ai.ask', signal_type: nil, context: {},
                      runtime: AgentLoop.runtime, id: nil, server: nil, initial_state: {})
          request_id = SecureRandom.uuid
          resolved_server = server || self.server(runtime: runtime, id: id || server_id, initial_state: initial_state)
          resolved_signal_type = signal_type || react_entry_signal
          signal = AgentLoop::Signal.new(
            type: resolved_signal_type,
            source: source,
            data: { prompt: prompt }.merge(data)
          )

          async_context = context.merge(request_id: request_id, async_request: true)
          initial_result = resolved_server.call(signal, context: async_context)
          Request.new(
            id: request_id,
            server: resolved_server,
            signal_type: resolved_signal_type,
            created_at: Time.now.utc,
            initial_result: initial_result
          )
        end

        def ask(prompt:, data: {}, source: 'agent_loop://ai.ask', signal_type: nil,
                context: {}, timeout: 15, poll_interval: 0.05,
                runtime: AgentLoop.runtime, id: nil, server: nil, initial_state: {})
          request = ask_async(
            prompt: prompt,
            data: data,
            source: source,
            signal_type: signal_type,
            context: context,
            runtime: runtime,
            id: id,
            server: server,
            initial_state: initial_state
          )
          await(request, timeout: timeout, poll_interval: poll_interval)
        end

        def ask_sync(prompt:, data: {}, source: 'agent_loop://ai.ask', signal_type: nil,
                     context: {}, timeout: 15, poll_interval: 0.05,
                     runtime: AgentLoop.runtime, id: nil, server: nil, initial_state: {})
          ask(
            prompt: prompt,
            data: data,
            source: source,
            signal_type: signal_type,
            context: context,
            timeout: timeout,
            poll_interval: poll_interval,
            runtime: runtime,
            id: id,
            server: server,
            initial_state: initial_state
          )
        end

        def await(request, timeout: 15, poll_interval: 0.05)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

          loop do
            loop_state = request.server.state.dig(:__strategy__, :reasoning_loop) || {}
            status = loop_state[:status]

            return terminal_result(request, loop_state) if TERMINAL_STATUSES.include?(status)

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Timeout::Error, "Timed out waiting for request #{request.id}" if now >= deadline

            sleep(poll_interval)
          end
        end

        def status(runtime: AgentLoop.runtime, id: nil, server: nil)
          resolved_server = server || self.server(runtime: runtime, id: id || server_id)
          resolved_server.state.dig(:__strategy__, :reasoning_loop) || {}
        end

        def tool_activity(runtime: AgentLoop.runtime, id: nil, server: nil)
          Array(status(runtime: runtime, id: id, server: server)[:tool_calls])
        end

        private

        def terminal_result(request, loop_state)
          {
            ok: loop_state[:status] == :success,
            request_id: request.id,
            status: loop_state[:status],
            result: loop_state[:result],
            answer: loop_state[:result],
            reason: loop_state[:termination_reason],
            iterations: loop_state[:iterations],
            tool_calls: Array(loop_state[:tool_calls]),
            phase: loop_state[:phase],
            raw: loop_state
          }
        end
      end
    end
  end
end
