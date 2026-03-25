# frozen_string_literal: true

module AgentLoop
  module Effects
    class Emit < Base
      attr_reader :signal, :type, :data, :source, :subject, :metadata, :datacontenttype, :dataschema,
                  :time, :id, :specversion, :target

      def initialize(type: nil, data: {}, source: nil, subject: nil, metadata: {}, datacontenttype: nil,
                     dataschema: nil, time: nil, id: nil, specversion: nil, target: nil, signal: nil)
        @signal = signal
        @type = type
        @data = data
        @source = source
        @subject = subject
        @metadata = metadata
        @datacontenttype = datacontenttype
        @dataschema = dataschema
        @time = time
        @id = id
        @specversion = specversion
        @target = target

        return if @signal

        raise ArgumentError, 'Emit requires signal or type' if @type.nil?
      end

      def to_signal(default_source:, default_metadata: {})
        return signal if signal.is_a?(AgentLoop::Signal)

        emitted_time = time || Time.now.utc

        AgentLoop::Signal.new(
          type: type,
          source: source || default_source,
          data: data,
          subject: subject,
          metadata: merged_metadata(default_metadata),
          datacontenttype: datacontenttype || AgentLoop::Signal::JSON_CONTENT_TYPE,
          dataschema: dataschema,
          time: emitted_time,
          id: id || AgentLoop::Signal.generate_id(time: emitted_time),
          specversion: specversion || AgentLoop::Signal::SPECVERSION
        )
      end

      private

      def merged_metadata(default_metadata)
        AgentLoop::Signal.symbolize_keys(default_metadata).merge(AgentLoop::Signal.symbolize_keys(metadata))
      end
    end
  end
end
