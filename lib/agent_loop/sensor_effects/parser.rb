# frozen_string_literal: true

module AgentLoop
  module SensorEffects
    module Parser
      class << self
        def parse_many(raw_effects, raw_signals: [])
          parsed_signals = Array(raw_signals).map { |signal| Emit.new(signal: signal) }
          parsed_effects = Array(raw_effects).map { |effect| parse(effect) }

          parsed_signals + parsed_effects
        end

        def parse(raw)
          return raw if raw.is_a?(Base)
          return Emit.new(signal: raw) if raw.is_a?(AgentLoop::Signal)

          if raw.is_a?(Hash)
            type = fetch_hash(raw, :type).to_sym
            return parse_hash(type, raw)
          end

          if raw.is_a?(Array)
            type = raw[0].to_sym
            return parse_tuple(type, raw)
          end

          raise AgentLoop::SensorRuntimeError.new(
            "Unsupported sensor effect: #{raw.inspect}",
            code: :unsupported_sensor_effect
          )
        end

        private

        def parse_hash(type, raw)
          case type
          when :emit
            Emit.new(signal: fetch_hash(raw, :signal), target: raw[:target] || raw['target'])
          when :schedule
            Schedule.new(delay_ms: fetch_hash(raw, :delay_ms), event: raw[:event] || raw['event'] || :tick)
          when :connect
            Connect.new(adapter: fetch_hash(raw, :adapter), opts: raw[:opts] || raw['opts'] || {})
          when :disconnect
            Disconnect.new(adapter: fetch_hash(raw, :adapter))
          when :subscribe
            Subscribe.new(topic: fetch_hash(raw, :topic), adapter: raw[:adapter] || raw['adapter'])
          when :unsubscribe
            Unsubscribe.new(topic: fetch_hash(raw, :topic), adapter: raw[:adapter] || raw['adapter'])
          else
            raise AgentLoop::SensorRuntimeError.new(
              "Unsupported sensor effect type: #{type}",
              code: :unsupported_sensor_effect
            )
          end
        end

        def parse_tuple(type, raw)
          case type
          when :emit
            Emit.new(signal: raw[1], target: raw[2])
          when :schedule
            Schedule.new(delay_ms: raw[1], event: raw[2] || :tick)
          when :connect
            Connect.new(adapter: raw[1], opts: raw[2] || {})
          when :disconnect
            Disconnect.new(adapter: raw[1])
          when :subscribe
            if raw.size == 2
              Subscribe.new(topic: raw[1])
            else
              Subscribe.new(adapter: raw[1], topic: raw[2])
            end
          when :unsubscribe
            if raw.size == 2
              Unsubscribe.new(topic: raw[1])
            else
              Unsubscribe.new(adapter: raw[1], topic: raw[2])
            end
          else
            raise AgentLoop::SensorRuntimeError.new(
              "Unsupported sensor effect type: #{type}",
              code: :unsupported_sensor_effect
            )
          end
        end

        def fetch_hash(hash, key)
          return hash[key] if hash.key?(key)

          string_key = key.to_s
          return hash[string_key] if hash.key?(string_key)

          raise KeyError, "Missing key #{key}"
        end
      end
    end
  end
end
