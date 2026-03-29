# frozen_string_literal: true

require 'zeitwerk'

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect(
  'ai' => 'AI'
)
loader.setup

module AgentLoop
  class Error < StandardError; end

  class << self
    def configure
      yield self
      reset_runtime!
    end

    def runtime
      return @runtime if defined?(@runtime) && @runtime

      runtime_mutex.synchronize do
        @runtime ||= runtime_builder.call
      end
    end

    def runtime=(runtime)
      runtime_mutex.synchronize do
        @runtime = runtime
      end
    end

    def runtime_builder
      @runtime_builder ||= lambda {
        server_manager = AgentLoop::ServerManager.new
        effect_executor = AgentLoop::Effects::Executor.new(
          emit_adapter: AgentLoop::Adapters::Emitter::Null.new,
          server_manager: server_manager
        )

        AgentLoop::Runtime.new(effect_executor: effect_executor)
      }
    end

    def runtime_builder=(builder)
      raise ArgumentError, 'runtime_builder must respond to #call' unless builder.respond_to?(:call)

      runtime_mutex.synchronize do
        @runtime_builder = builder
        @runtime = nil
      end
    end

    def reset_runtime!
      runtime_mutex.synchronize do
        @runtime = nil
      end
    end

    def sensor_manager
      return @sensor_manager if defined?(@sensor_manager) && @sensor_manager

      runtime_mutex.synchronize do
        @sensor_manager ||= AgentLoop::SensorManager.new
      end
    end

    def sensor_manager=(manager)
      runtime_mutex.synchronize do
        @sensor_manager = manager
      end
    end

    private

    def runtime_mutex
      @runtime_mutex ||= Mutex.new
    end
  end
end
