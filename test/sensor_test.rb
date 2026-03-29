# frozen_string_literal: true

require 'test_helper'

class SensorTest < Minitest::Test
  class ExampleSensor
    include AgentLoop::Sensor

    name 'example_sensor'
    description 'Example sensor for tests'

    schema do
      required(:interval_ms).filled(:integer)
      optional(:topic).filled(:string)
    end

    def init(config, context: {})
      _context = context
      [:ok, { interval_ms: config.fetch(:interval_ms) }]
    end

    def handle_event(event, state, context: {})
      _context = context
      return [:ok, state, [[:schedule, state.fetch(:interval_ms)]]] if event == :tick

      %i[error unsupported_event]
    end
  end

  def test_validates_sensor_config
    config = ExampleSensor.validate_config!('interval_ms' => 1000, 'topic' => 'orders')

    assert_equal 1000, config[:interval_ms]
    assert_equal 'orders', config[:topic]
  end

  def test_raises_on_invalid_sensor_config
    error = assert_raises(AgentLoop::Sensor::InvalidConfig) do
      ExampleSensor.validate_config!('topic' => 'orders')
    end

    assert_equal({ interval_ms: ['is missing'] }, error.details)
  end

  def test_normalizes_callback_results
    sensor = ExampleSensor.new
    result = sensor.normalize_sensor_result([:ok, { count: 1 }, [[:schedule, 50]]], current_state: {},
                                                                                    phase: :handle_event)

    assert_equal :ok, result.status
    assert_equal({ count: 1 }, result.state)
    assert_equal [[:schedule, 50]], result.effects
  end

  def test_normalizes_error_tuple
    sensor = ExampleSensor.new
    result = sensor.normalize_sensor_result(%i[error boom], current_state: { count: 1 }, phase: :handle_event)

    assert_equal :error, result.status
    assert_equal :sensor_callback_error, result.error[:code]
    assert_equal({ count: 1 }, result.state)
  end
end
