# frozen_string_literal: true

require_relative "../tool"

module AgentLoop
  module Adapters
    module Tools
      class Null < AgentLoop::Adapters::Tool
        def run(name:, input:, instance:, runtime:)
          {
            ok: true,
            adapter: self.class.name,
            tool: name,
            input: input,
            instance_id: instance.id,
            runtime: runtime.class.name
          }
        end
      end
    end
  end
end
