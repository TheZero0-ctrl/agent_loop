# frozen_string_literal: true

module AgentLoop
  class SensorResult
    attr_reader :state, :signals, :effects, :status, :error

    def initialize(state:, signals: [], effects: [], status: :ok, error: nil)
      @state = state
      @signals = Array(signals)
      @effects = Array(effects)
      @status = status
      @error = error
    end

    def ok?
      status == :ok
    end
  end
end
