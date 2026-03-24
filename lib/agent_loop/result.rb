# frozen_string_literal: true

module AgentLoop
  class Result
    attr_reader :state, :state_ops, :effects, :status, :error

    def initialize(state:, state_ops: [], effects: [], status: :ok, error: nil)
      @state = state
      @state_ops = Array(state_ops)
      @effects = Array(effects)
      @status = status
      @error = error
    end

    def ok?
      status == :ok
    end
  end
end
