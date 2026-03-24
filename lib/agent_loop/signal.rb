# frozen_string_literal: true

require "securerandom"

module AgentLoop
  class Signal
    attr_reader :id, :type, :source, :data, :subject, :time, :metadata

    def initialize(type:, source:, data: {}, subject: nil, metadata: {}, id: SecureRandom.uuid, time: Time.now.utc)
      @id = id
      @type = type
      @source = source
      @data = data
      @subject = subject
      @time = time
      @metadata = metadata
    end

    def meta
      metadata
    end
  end
end
