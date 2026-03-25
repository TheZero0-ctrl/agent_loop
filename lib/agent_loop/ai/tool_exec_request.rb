# frozen_string_literal: true

require 'securerandom'

module AgentLoop
  module AI
    class ToolExecRequest
      attr_reader :id, :tool_name, :arguments, :action_class, :instance_id, :callback_event, :trace_id,
                  :correlation_id, :causation_id, :requested_at, :context, :action_ref

      def initialize(tool_name:, arguments:, action_class:, instance_id:, callback_event: nil, trace_id: nil,
                     correlation_id: nil, causation_id: nil, requested_at: Time.now.utc, context: {},
                     action_ref: nil, id: SecureRandom.uuid)
        @id = id
        @tool_name = tool_name
        @arguments = arguments
        @action_class = action_class
        @instance_id = instance_id
        @callback_event = callback_event
        @trace_id = trace_id
        @correlation_id = correlation_id
        @causation_id = causation_id
        @requested_at = requested_at
        @context = context
        @action_ref = action_ref || default_action_ref(action_class)
      end

      def name
        tool_name
      end

      def to_h
        {
          id: id,
          tool_name: tool_name,
          arguments: arguments,
          action_class: action_class,
          action_ref: action_ref,
          instance_id: instance_id,
          callback_event: callback_event,
          trace_id: trace_id,
          correlation_id: correlation_id,
          causation_id: causation_id,
          requested_at: requested_at,
          context: context
        }
      end

      private

      def default_action_ref(action_class)
        "#{action_class.name}@v1"
      end
    end
  end
end
