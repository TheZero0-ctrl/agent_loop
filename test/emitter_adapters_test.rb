# frozen_string_literal: true

require 'stringio'
require 'test_helper'

class EmitterAdaptersTest < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def request(uri:, method:, headers:, body:, open_timeout:, read_timeout:)
      @calls << {
        uri: uri,
        method: method,
        headers: headers,
        body: body,
        open_timeout: open_timeout,
        read_timeout: read_timeout
      }
      { status: 202, body: 'accepted', headers: {} }
    end
  end

  class FakePublisher
    attr_reader :published

    def initialize
      @published = []
    end

    def publish(topic, message)
      @published << { topic: topic, message: message }
    end
  end

  def build_signal
    AgentLoop::Signal.new(type: 'support.ticket.created', source: '/tests', data: { id: 'tkt_1' })
  end

  def test_console_adapter_writes_json_payload
    io = StringIO.new
    adapter = AgentLoop::Adapters::Emitter::Console.new(io: io)

    adapter.emit(build_signal, target: 'console')

    assert_includes io.string, 'support.ticket.created'
    assert_includes io.string, 'console'
  end

  def test_http_adapter_posts_json_payload
    client = FakeClient.new
    adapter = AgentLoop::Adapters::Emitter::Http.new(endpoint: 'https://example.com/events', client: client)

    result = adapter.emit(build_signal)

    assert_equal 202, result[:status]
    assert_equal 'accepted', result[:body]
    assert_equal 'https://example.com/events', client.calls.first[:uri].to_s
  end

  def test_webhook_adapter_adds_signature_headers
    client = FakeClient.new
    adapter = AgentLoop::Adapters::Emitter::Webhook.new(
      endpoint: 'https://example.com/webhook',
      secret: 'shhh',
      client: client
    )

    adapter.emit(build_signal)

    headers = client.calls.first[:headers]

    assert headers['X-Signature-Timestamp']
    assert headers['X-Signature-SHA256']
  end

  def test_pubsub_adapter_publishes_signal_payload
    publisher = FakePublisher.new
    adapter = AgentLoop::Adapters::Emitter::Pubsub.new(topic: 'events', publisher: publisher)

    adapter.emit(build_signal)

    assert_equal 'events', publisher.published.first[:topic]
    assert_equal 'support.ticket.created', publisher.published.first[:message][:type]
  end

  def test_fanout_adapter_emits_to_all_adapters
    in_process = AgentLoop::Adapters::Emitter::InProcess.new
    pubsub_publisher = FakePublisher.new
    pubsub = AgentLoop::Adapters::Emitter::Pubsub.new(topic: 'events', publisher: pubsub_publisher)
    fanout = AgentLoop::Adapters::Emitter::Fanout.new(adapters: [in_process, pubsub])

    fanout.emit(build_signal)

    assert_equal 1, in_process.events.size
    assert_equal 1, pubsub_publisher.published.size
  end

  def test_signal_dispatch_uses_adapter_specs
    io = StringIO.new
    signal = build_signal

    AgentLoop::Signal::Dispatch.dispatch(signal, [
                                           [:console, { io: io }],
                                           [:noop, {}]
                                         ])

    assert_includes io.string, 'support.ticket.created'
  end
end
