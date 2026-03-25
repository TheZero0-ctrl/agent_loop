# frozen_string_literal: true

require 'test_helper'

class SignalTest < Minitest::Test
  UUID_V7_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  def test_new_populates_cloudevents_style_defaults
    signal = AgentLoop::Signal.new(
      type: 'ticket.opened',
      source: '/support',
      data: { 'id' => 'tkt_123' }
    )

    assert_equal '1.0.2', signal.specversion
    assert_match UUID_V7_REGEX, signal.id
    assert_equal 'application/json', signal.datacontenttype
    assert_equal 'ticket.opened', signal.type
    assert_equal '/support', signal.source
    assert_equal({ 'id' => 'tkt_123' }, signal.data)
  end

  def test_new_symbolizes_metadata_keys
    signal = AgentLoop::Signal.new(
      type: 'ticket.updated',
      source: '/support',
      metadata: { 'trace_id' => 'trace-1', 'nested' => { 'correlation_id' => 'corr-1' } }
    )

    assert_equal 'trace-1', signal.metadata[:trace_id]
    assert_equal 'corr-1', signal.metadata.dig(:nested, :correlation_id)
  end

  def test_new_bang_constructor
    signal = AgentLoop::Signal.new!('ticket.closed', { id: 'tkt_9' }, source: '/support')

    assert_equal 'ticket.closed', signal.type
    assert_equal({ id: 'tkt_9' }, signal.data)
  end
end
