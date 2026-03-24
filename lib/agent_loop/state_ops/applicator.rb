# frozen_string_literal: true

module AgentLoop
  module StateOps
    class Applicator
      class UnsupportedStateOp < StandardError; end

      def apply_all(state, state_ops)
        Array(state_ops).reduce(state) do |current_state, state_op|
          apply(current_state, state_op)
        end
      end

      def apply(state, state_op)
        case state_op
        when AgentLoop::StateOps::SetState
          deep_merge(state, state_op.attrs)
        when AgentLoop::StateOps::ReplaceState
          deep_dup(state_op.state)
        when AgentLoop::StateOps::DeleteKeys
          state.reject { |key, _value| state_op.keys.include?(key) }
        when AgentLoop::StateOps::SetPath
          set_path(state, state_op.path, state_op.value)
        when AgentLoop::StateOps::DeletePath
          delete_path(state, state_op.path)
        else
          raise UnsupportedStateOp, "Unsupported state op: #{state_op.class}"
        end
      end

      private

      def deep_merge(left, right)
        return deep_dup(right) unless left.is_a?(Hash) && right.is_a?(Hash)

        left.each_with_object(deep_dup(right)) do |(key, value), memo|
          memo[key] = if memo.key?(key)
                        deep_merge(value, memo[key])
                      else
                        deep_dup(value)
                      end
        end
      end

      def set_path(state, path, value)
        updated = deep_dup(state)
        last_key = path.last
        cursor = updated

        path[0...-1].each do |key|
          cursor[key] = {} unless cursor[key].is_a?(Hash)
          cursor = cursor[key]
        end

        cursor[last_key] = deep_dup(value)
        updated
      end

      def delete_path(state, path)
        updated = deep_dup(state)
        cursor = updated

        path[0...-1].each do |key|
          return updated unless cursor[key].is_a?(Hash)

          cursor = cursor[key]
        end

        cursor.delete(path.last)
        updated
      end

      def deep_dup(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(key, value), memo| memo[key] = deep_dup(value) }
        when Array
          obj.map { |value| deep_dup(value) }
        else
          obj
        end
      end
    end
  end
end
