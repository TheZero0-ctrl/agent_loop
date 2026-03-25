# frozen_string_literal: true

require "time"
require "uuid7"

module AgentLoop
  class Signal
    SPECVERSION = "1.0.2"
    JSON_CONTENT_TYPE = "application/json"

    attr_reader :specversion, :id, :type, :source, :subject, :time,
                :datacontenttype, :dataschema, :data, :metadata

    def self.new!(type, data = {}, **attrs)
      new(type: type, data: data, **attrs)
    end

    def self.from_h(attrs)
      new(**symbolize_keys(attrs))
    end

    def initialize(type:, source:, data: {}, subject: nil, metadata: {}, time: Time.now.utc, id: nil,
                   specversion: SPECVERSION, datacontenttype: JSON_CONTENT_TYPE,
                   dataschema: nil)
      @specversion = specversion.to_s
      @type = type.to_s
      @source = source.to_s
      @subject = subject
      @time = normalize_time(time)
      @id = (id || self.class.generate_id(time: @time)).to_s
      @datacontenttype = datacontenttype.to_s
      @dataschema = dataschema
      @data = deep_dup(data)
      @metadata = self.class.symbolize_keys(deep_dup(metadata))

      validate!
    end

    def self.generate_id(time: Time.now.utc)
      timestamp = normalize_timestamp(time)
      UUID7.generate(timestamp: timestamp)
    rescue ArgumentError
      UUID7.generate
    end

    def meta
      metadata
    end

    def to_h
      {
        specversion: specversion,
        id: id,
        type: type,
        source: source,
        subject: subject,
        time: time,
        datacontenttype: datacontenttype,
        dataschema: dataschema,
        data: data,
        metadata: metadata
      }
    end

    def self.symbolize_keys(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(key, value), result|
        normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
        result[normalized_key] =
          if value.is_a?(Hash)
            symbolize_keys(value)
          elsif value.is_a?(Array)
            value.map { |entry| entry.is_a?(Hash) ? symbolize_keys(entry) : entry }
          else
            value
          end
      end
    end

    def self.normalize_timestamp(value)
      return (value.to_r * 1000).to_i if value.is_a?(Time)
      return value.to_i if value.is_a?(Numeric)
      return (Time.parse(value).to_r * 1000).to_i if value.is_a?(String)

      Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    rescue ArgumentError
      Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    end
    private_class_method :normalize_timestamp

    private

    def normalize_time(value)
      return value if value.is_a?(Time)
      return Time.parse(value) if value.is_a?(String)

      Time.now.utc
    rescue ArgumentError
      Time.now.utc
    end

    def deep_dup(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), memo| memo[k] = deep_dup(v) }
      when Array
        obj.map { |entry| deep_dup(entry) }
      else
        obj
      end
    end

    def validate!
      raise ArgumentError, "Signal type is required" if type.empty?
      raise ArgumentError, "Signal source is required" if source.empty?
      raise ArgumentError, "Signal specversion is required" if specversion.empty?
    end
  end
end
