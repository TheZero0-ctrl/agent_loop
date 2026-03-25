# frozen_string_literal: true

require_relative '../tool'

module AgentLoop
  module Adapters
    module Tools
      class Null < AgentLoop::Adapters::Tool
        def run(name:, input:, instance:, runtime:, meta: {})
          {
            ok: true,
            adapter: self.class.name,
            tool: name,
            input: input,
            instance_id: instance.id,
            runtime: runtime.class.name,
            meta: meta
          }
        end
      end
    end
  end
end
