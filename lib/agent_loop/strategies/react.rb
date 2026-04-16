# frozen_string_literal: true

require 'securerandom'
require 'time'

module AgentLoop
  module Strategies
    class React < ReasoningLoop
      attr_reader :tool_actions

      TOOL_RESULT_ACTION = :react_tool_result
      QUERY_ACTION = :react_query
      REACT_KEY = :react
      DEFAULT_CONTINUATION_MODE = :inline
      DEFAULT_TOOL_CALLBACK_SIGNAL = 'agent_loop.strategy.react.tool_result'
      DEFAULT_ENTRY_SIGNALS = ['ai.react.query'].freeze

      def initialize(tools: [], model: nil,
                     system_prompt: AgentLoop::AI::RubyLlmReactPlanner::DEFAULT_SYSTEM_PROMPT,
                     max_turns: 8, request_timeout_s: 30, strict_tools: true,
                     tick_delay_ms: 25, tool_callback_signal: DEFAULT_TOOL_CALLBACK_SIGNAL,
                     entry_signals: DEFAULT_ENTRY_SIGNALS,
                     continuation_mode: DEFAULT_CONTINUATION_MODE)
        super(tick_delay_ms: tick_delay_ms)
        @tool_callback_signal = tool_callback_signal
        @tool_actions = Array(tools)
        @entry_signals = Array(entry_signals).map(&:to_s).uniq
        @max_turns = Integer(max_turns)
        @continuation_mode = normalize_continuation_mode(continuation_mode)
        @decision_engine = AgentLoop::AI::RubyLlmReactPlanner.new(
          actions: @tool_actions,
          model: model,
          system_prompt: system_prompt,
          max_turns: max_turns,
          request_timeout_s: request_timeout_s,
          strict_tools: strict_tools
        )
      end

      def init(instance:, runtime:, context: {})
        _runtime = runtime
        _context = context

        AgentLoop::Result.new(
          state: instance.state || {},
          state_ops: merge_strategy_state_ops(
            status: :idle,
            phase: :idle,
            history: [],
            iterations: 0,
            tool_calls: [],
            request_id: nil,
            pending_tool: nil,
            termination_reason: nil,
            result: nil,
            react_key: REACT_KEY
          ),
          effects: []
        )
      end

      def signal_routes(context = {})
        _context = context
        query_routes = @entry_signals.map { |signal_type| [signal_type, [:strategy_cmd, QUERY_ACTION], 100] }

        query_routes + [
          ['agent_loop.strategy.tick', :strategy_tick, 100],
          [@tool_callback_signal, [:strategy_cmd, TOOL_RESULT_ACTION], 100]
        ]
      end

      def cmd(agent:, state:, instructions:, context:)
        _agent = agent
        loop_state = strategy_state(state)
        normalized_history = Array(loop_state[:history])
        iterations = Integer(loop_state[:iterations] || 0)
        tool_calls = Array(loop_state[:tool_calls])
        request_id = loop_state[:request_id]
        termination_reason = loop_state[:termination_reason]

        Array(instructions).each do |instruction|
          if instruction.action == TOOL_RESULT_ACTION
            normalized_history << { kind: :tool_result, payload: instruction.params }
            loop_state = loop_state.merge(pending_tool: nil, phase: :thinking)
            tool_calls = mark_tool_call_completed(tool_calls, instruction.params)
          else
            normalized_history << {
              kind: :input,
              action: instruction.action,
              params: instruction.params,
              signal_type: signal_type_from(context)
            }
            request_id = context[:request_id] || request_id || SecureRandom.uuid if instruction.action == QUERY_ACTION
            termination_reason = nil if instruction.action == QUERY_ACTION
          end
        end

        loop_state = loop_state.merge(history: normalized_history)

        status = :running
        phase = loop_state[:phase] || :thinking
        result_value = loop_state[:result]
        pending_tool = loop_state[:pending_tool]
        effects = []

        force_scheduled = context[:async_request] == true

        loop do
          if iterations >= @max_turns
            status, phase, result_value, pending_tool, effects, termination_reason = max_turns_failure
            break
          end

          decision = next_step(loop_state: loop_state, context: context)
          status, phase, result_value, pending_tool, effects, decision_reason, new_tool_call =
            apply_decision(decision, context: context, request_id: request_id)
          iterations += 1
          tool_calls << new_tool_call if new_tool_call
          termination_reason = decision_reason if decision_reason
          normalized_history << decision_history_entry(decision)

          loop_state = loop_state.merge(
            status: status,
            phase: phase,
            history: normalized_history,
            iterations: iterations,
            tool_calls: tool_calls,
            request_id: request_id,
            pending_tool: pending_tool,
            termination_reason: termination_reason,
            result: result_value
          )

          break unless continue_inline?(status: status, phase: phase, effects: effects,
                                        force_scheduled: force_scheduled)
        end

        strategy_ops = merge_strategy_state_ops(
          status: status,
          phase: phase,
          history: normalized_history,
          iterations: iterations,
          tool_calls: tool_calls,
          request_id: request_id,
          pending_tool: pending_tool,
          termination_reason: termination_reason,
          result: result_value
        )

        AgentLoop::Result.new(
          state: state,
          state_ops: strategy_ops,
          effects: effects,
          status: status == :failure ? :error : :ok,
          error: status == :failure ? { code: :react_failed, message: 'ReAct strategy decision failed' } : nil
        )
      end

      def tick(instance:, runtime:, context: {})
        _runtime = runtime
        agent = instance.agent_class.new
        cmd(agent: agent, state: instance.state || {}, instructions: [], context: context)
      end

      def snapshot(instance:, context: {})
        _context = context
        loop_state = strategy_state(instance.state || {})
        {
          strategy: self.class.name,
          instance_id: instance.id,
          status: loop_state[:status] || :idle,
          phase: loop_state[:phase] || :idle,
          request_id: loop_state[:request_id],
          iterations: loop_state[:iterations] || 0,
          pending_tool: loop_state[:pending_tool],
          termination_reason: loop_state[:termination_reason],
          tool_calls: Array(loop_state[:tool_calls]),
          done: %i[success failure].include?(loop_state[:status]),
          result: loop_state[:result]
        }
      end

      private

      def next_step(loop_state:, context:)
        @decision_engine.next_step(
          state: loop_state,
          context: context.merge(tool_callback_signal: @tool_callback_signal)
        ) || { type: :failure, message: 'empty_decision' }
      end

      def apply_decision(decision, context:, request_id:)
        case decision[:type]&.to_sym
        when :tool
          tool_call_id = decision[:tool_call_id] || SecureRandom.uuid
          pending_tool = {
            id: tool_call_id,
            name: decision.fetch(:name),
            input: decision.fetch(:input, {})
          }
          effect = AgentLoop::Effects::RunTool.new(
            name: pending_tool[:name],
            input: pending_tool[:input],
            callback_event: @tool_callback_signal,
            meta: {
              tool_call_id: tool_call_id,
              request_id: request_id,
              requested_at: Time.now.utc.iso8601
            }
          )
          call_record = {
            tool_call_id: tool_call_id,
            request_id: request_id,
            name: pending_tool[:name],
            input: pending_tool[:input],
            status: :requested,
            requested_at: Time.now.utc.iso8601
          }
          [:running, :waiting_tool, nil, pending_tool, [effect], nil, call_record]
        when :final
          [:success, :done, decision[:result], nil, [], :final_answer, nil]
        when :failure
          error = AgentLoop::Effects::Error.new(
            code: :react_failed,
            message: decision[:message] || 'ReAct decision failed',
            details: decision[:details] || {}
          )
          reason = decision[:message] == 'reasoning_turn_limit_exceeded' ? :max_turns : :decision_failure
          [:failure, :failed, nil, nil, [error], reason, nil]
        else
          effects = if @continuation_mode == :scheduled
                      [schedule_tick_effect(context, source: 'agent_loop://strategy/react')]
                    else
                      []
                    end
          [:running, :thinking, nil, nil, effects, nil, nil]
        end
      end

      def continue_inline?(status:, phase:, effects:, force_scheduled:)
        return false if force_scheduled

        status == :running && phase == :thinking && effects.empty? && inline_continuation_enabled?
      end

      def max_turns_failure
        error = AgentLoop::Effects::Error.new(
          code: :react_failed,
          message: 'reasoning_turn_limit_exceeded',
          details: { max_turns: @max_turns }
        )
        [:failure, :failed, nil, nil, [error], :max_turns]
      end

      def decision_history_entry(decision)
        {
          kind: :decision,
          type: (decision[:type] || :continue).to_sym,
          at: Time.now.utc.iso8601
        }
      end

      def mark_tool_call_completed(tool_calls, params)
        payload = params || {}
        tool_call_id = payload[:tool_call_id] || payload['tool_call_id']
        result = payload[:result] || payload['result']

        return tool_calls unless tool_call_id

        tool_calls.map do |entry|
          next entry unless entry[:tool_call_id] == tool_call_id

          entry.merge(status: :completed, result: result, completed_at: Time.now.utc.iso8601)
        end
      end

      def signal_type_from(context)
        signal = context[:signal]
        return signal.type if signal.respond_to?(:type)
        return signal[:type] if signal.is_a?(Hash)

        nil
      end

      def normalize_continuation_mode(mode)
        value = mode.to_sym
        return value if %i[inline scheduled].include?(value)

        raise ArgumentError, "Invalid continuation_mode: #{mode.inspect}"
      end

      def inline_continuation_enabled?
        @continuation_mode == :inline
      end
    end
  end
end
