# frozen_string_literal: true

require 'time'

module AgentLoop
  module Strategies
    class BehaviorTree < Base
      STRATEGY_KEY = :__strategy__
      TREE_KEY = :behavior_tree

      def initialize(tree:, tick_delay_ms: 25)
        @tree = tree
        @tick_delay_ms = tick_delay_ms
      end

      def init(instance:, runtime:, context: {})
        _runtime = runtime
        _context = context

        AgentLoop::Result.new(
          state: instance.state || {},
          state_ops: [
            AgentLoop::StateOps::SetPath.new(path: [STRATEGY_KEY, TREE_KEY, :status], value: :idle),
            AgentLoop::StateOps::SetPath.new(path: [STRATEGY_KEY, TREE_KEY, :cursor_path], value: nil)
          ],
          effects: []
        )
      end

      def cmd(agent:, state:, instructions:, context:)
        direct_result = AgentLoop::Strategies::Direct.new.cmd(
          agent: agent,
          state: state,
          instructions: instructions,
          context: context
        )
        return direct_result unless direct_result.ok?

        tree_state = strategy_tree_state(direct_result.state)
        result = tick_node(
          @tree,
          agent: agent,
          state: direct_result.state,
          context: context,
          cursor_path: tree_state[:cursor_path],
          path: []
        )

        strategy_ops = [
          AgentLoop::StateOps::SetPath.new(path: [STRATEGY_KEY, TREE_KEY, :status], value: result.status),
          AgentLoop::StateOps::SetPath.new(path: [STRATEGY_KEY, TREE_KEY, :cursor_path], value: result.cursor_path),
          AgentLoop::StateOps::SetPath.new(path: [STRATEGY_KEY, TREE_KEY, :last_updated_at],
                                           value: Time.now.utc.iso8601)
        ]

        effects = Array(direct_result.effects) + Array(result.effects)
        effects << schedule_tick_effect(context) if result.status == :running

        AgentLoop::Result.new(
          state: result.state,
          state_ops: Array(direct_result.state_ops) + Array(result.state_ops) + strategy_ops,
          effects: effects,
          status: :ok,
          error: nil
        )
      rescue StandardError => e
        AgentLoop::Result.new(
          state: state,
          state_ops: [
            AgentLoop::StateOps::SetPath.new(path: [STRATEGY_KEY, TREE_KEY, :status], value: :failure)
          ],
          effects: [AgentLoop::Effects::Error.new(code: :behavior_tree_failed, message: e.message, details: {})],
          status: :error,
          error: { code: :behavior_tree_failed, message: e.message }
        )
      end

      def tick(instance:, runtime:, context: {})
        _runtime = runtime
        agent = instance.agent_class.new
        cmd(agent: agent, state: instance.state || {}, instructions: [], context: context)
      end

      def snapshot(instance:, context: {})
        _context = context
        tree_state = strategy_tree_state(instance.state || {})
        {
          strategy: self.class.name,
          instance_id: instance.id,
          status: tree_state[:status] || :idle,
          cursor_path: tree_state[:cursor_path],
          done: %i[success failure].include?(tree_state[:status])
        }
      end

      private

      def strategy_tree_state(state)
        ((state || {}).dig(STRATEGY_KEY, TREE_KEY) || {}).transform_keys(&:to_sym)
      end

      def tick_node(node, agent:, state:, context:, cursor_path:, path:)
        case node
        when AgentLoop::BehaviorTree::Sequence
          tick_sequence(node, agent: agent, state: state, context: context, cursor_path: cursor_path, path: path)
        when AgentLoop::BehaviorTree::Selector
          tick_selector(node, agent: agent, state: state, context: context, cursor_path: cursor_path, path: path)
        when AgentLoop::BehaviorTree::Action
          tick_action(node, agent: agent, state: state, context: context)
        when AgentLoop::BehaviorTree::Condition
          tick_condition(node, state: state, context: context)
        else
          raise AgentLoop::BehaviorTree::InvalidNode, "Unsupported behavior tree node: #{node.class}"
        end
      end

      def tick_sequence(node, agent:, state:, context:, cursor_path:, path:)
        start_idx = composite_start_index(node, cursor_path: cursor_path, path: path)
        current_state = state
        state_ops = []
        effects = []

        node.children.each_with_index do |child, idx|
          next if idx < start_idx

          result = tick_node(
            child,
            agent: agent,
            state: current_state,
            context: context,
            cursor_path: cursor_path,
            path: path + [idx]
          )

          current_state = result.state
          state_ops.concat(Array(result.state_ops))
          effects.concat(Array(result.effects))

          case result.status
          when :success
            next
          when :running
            return AgentLoop::BehaviorTree::NodeResult.new(
              status: :running,
              state: current_state,
              state_ops: state_ops,
              effects: effects,
              cursor_path: result.cursor_path || (path + [idx])
            )
          else
            return AgentLoop::BehaviorTree::NodeResult.new(
              status: :failure,
              state: current_state,
              state_ops: state_ops,
              effects: effects,
              cursor_path: nil
            )
          end
        end

        AgentLoop::BehaviorTree::NodeResult.new(
          status: :success,
          state: current_state,
          state_ops: state_ops,
          effects: effects,
          cursor_path: nil
        )
      end

      def tick_selector(node, agent:, state:, context:, cursor_path:, path:)
        start_idx = composite_start_index(node, cursor_path: cursor_path, path: path)
        current_state = state
        state_ops = []
        effects = []

        node.children.each_with_index do |child, idx|
          next if idx < start_idx

          result = tick_node(
            child,
            agent: agent,
            state: current_state,
            context: context,
            cursor_path: cursor_path,
            path: path + [idx]
          )

          current_state = result.state
          state_ops.concat(Array(result.state_ops))
          effects.concat(Array(result.effects))

          case result.status
          when :success
            return AgentLoop::BehaviorTree::NodeResult.new(
              status: :success,
              state: current_state,
              state_ops: state_ops,
              effects: effects,
              cursor_path: nil
            )
          when :running
            return AgentLoop::BehaviorTree::NodeResult.new(
              status: :running,
              state: current_state,
              state_ops: state_ops,
              effects: effects,
              cursor_path: result.cursor_path || (path + [idx])
            )
          else
            next
          end
        end

        AgentLoop::BehaviorTree::NodeResult.new(
          status: :failure,
          state: current_state,
          state_ops: state_ops,
          effects: effects,
          cursor_path: nil
        )
      end

      def tick_action(node, agent:, state:, context:)
        result = agent.cmd(state, node.instruction, context: context)
        status = result.ok? ? :success : :failure
        cursor_path = status == :success ? nil : []

        AgentLoop::BehaviorTree::NodeResult.new(
          status: status,
          state: apply_result_state(result),
          state_ops: result.state_ops,
          effects: result.effects,
          cursor_path: cursor_path
        )
      end

      def tick_condition(node, state:, context:)
        outcome = node.call(state: state, context: context)
        status = if outcome == :running
                   :running
                 elsif outcome
                   :success
                 else
                   :failure
                 end

        AgentLoop::BehaviorTree::NodeResult.new(
          status: status,
          state: state,
          state_ops: [],
          effects: [],
          cursor_path: nil
        )
      end

      def composite_start_index(node, cursor_path:, path:)
        return 0 unless cursor_path.is_a?(Array)
        return 0 if cursor_path.length <= path.length
        return 0 unless cursor_path[0, path.length] == path

        candidate = cursor_path[path.length]
        return 0 unless candidate.is_a?(Integer)

        candidate.clamp(0, node.children.length)
      end

      def apply_result_state(result)
        AgentLoop::StateOps::Applicator.new.apply_all(result.state, result.state_ops)
      end

      def schedule_tick_effect(context)
        signal = AgentLoop::Signal.new(
          type: 'agent_loop.strategy.tick',
          source: 'agent_loop://strategy/behavior_tree',
          data: {},
          metadata: {
            trace_id: context[:trace_id],
            correlation_id: context[:correlation_id]
          }.compact
        )

        AgentLoop::Effects::Schedule.new(delay_ms: @tick_delay_ms, signal: signal)
      end
    end
  end
end
