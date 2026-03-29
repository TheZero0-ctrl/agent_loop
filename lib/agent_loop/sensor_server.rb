# frozen_string_literal: true

require 'securerandom'

module AgentLoop
  class SensorServer
    class QueueOverflow < StandardError
    end

    EventReply = Struct.new(:mutex, :condition, :done, :result, :error)
    EventEnvelope = Struct.new(:event, :context, :reply)
    EffectEnvelope = Struct.new(:effect)

    DEFAULT_MAX_QUEUE_SIZE = 10_000
    TERMINAL_STATUSES = %i[failed stopped].freeze

    class << self
      def start(sensor:, config: {}, context: {}, id: nil, sensor_instance: nil,
                registry: AgentLoop::SensorRegistry,
                max_event_queue_size: DEFAULT_MAX_QUEUE_SIZE,
                max_effect_queue_size: DEFAULT_MAX_QUEUE_SIZE,
                effect_executor: AgentLoop::SensorEffects::Executor.new,
                adapters: {}, default_adapter: :default)
        instance = sensor_instance || AgentLoop::SensorInstance.new(
          sensor_class: sensor,
          id: id || SecureRandom.uuid,
          context: context
        )

        new(
          sensor_instance: instance,
          config: config,
          registry: registry,
          max_event_queue_size: max_event_queue_size,
          max_effect_queue_size: max_effect_queue_size,
          effect_executor: effect_executor,
          adapters: adapters,
          default_adapter: default_adapter
        ).tap(&:start)
      end

      alias start_link start

      def whereis(id, registry: AgentLoop::SensorRegistry)
        registry.whereis(id)
      end
    end

    attr_reader :instance

    def initialize(sensor_instance:, config:, registry: AgentLoop::SensorRegistry,
                   max_event_queue_size: DEFAULT_MAX_QUEUE_SIZE,
                   max_effect_queue_size: DEFAULT_MAX_QUEUE_SIZE,
                   effect_executor: AgentLoop::SensorEffects::Executor.new,
                   adapters: {}, default_adapter: :default)
      @instance = sensor_instance
      @sensor = sensor_instance.sensor_class.new
      @config = config || {}
      @registry = registry
      @max_event_queue_size = max_event_queue_size
      @max_effect_queue_size = max_effect_queue_size
      @effect_executor = effect_executor
      @event_mailbox = Queue.new
      @effect_mailbox = Queue.new
      @mutex = Mutex.new
      @completion_condition = ConditionVariable.new
      @event_queue_depth = 0
      @effect_queue_depth = 0
      @status = :idle
      @worker_thread = nil
      @timer_threads = []
      @default_adapter = default_adapter
      @adapters = { default_adapter => AgentLoop::SensorAdapters::Null.new }.merge(adapters || {})
    end

    def start
      return self if mutex.synchronize { @worker_thread&.alive? }

      bootstrap!

      mutex.synchronize do
        return self if @worker_thread&.alive?

        registry.register(instance.id, self)
        @worker_thread = Thread.new { run_loop }
        @worker_thread.name = "agent-loop-sensor-#{instance.id}" if @worker_thread.respond_to?(:name=)
      end

      self
    rescue StandardError
      registry.unregister(instance.id)
      raise
    end

    def event(payload, context: {})
      enqueue_event(payload, context: context)
      :ok
    end

    def event!(payload, context: {})
      reply = EventReply.new(Mutex.new, ConditionVariable.new, false)
      enqueue_event(payload, context: context, reply: reply)

      reply.mutex.synchronize do
        reply.condition.wait(reply.mutex) until reply.done
      end

      raise reply.error if reply.error

      reply.result
    end

    def stop(reason: nil)
      mutex.synchronize do
        return :ok if @status == :stopped

        @status = :stopped
        instance.status = :stopped
        instance.metadata[:stop_reason] = reason if reason
        completion_condition.broadcast
      end

      event_mailbox << :__stop__
      worker_thread&.join
      cancel_timers
      safely_terminate(reason)
      registry.unregister(instance.id)
      :ok
    end

    def status
      mutex.synchronize { @status }
    end

    def state
      mutex.synchronize { instance.state }
    end

    def await_completion(timeout: nil)
      deadline = timeout ? monotonic_now + timeout : nil

      mutex.synchronize do
        until TERMINAL_STATUSES.include?(@status)
          remaining = deadline && (deadline - monotonic_now)
          return nil if remaining && remaining <= 0

          completion_condition.wait(mutex, remaining)
        end
      end

      snapshot
    end

    def snapshot
      {
        sensor: {
          id: instance.id,
          class: instance.sensor_class.to_s,
          status: instance.status,
          state: instance.state,
          metadata: instance.metadata,
          context: instance.context
        },
        server: {
          status: status,
          event_queue_depth: event_queue_depth,
          effect_queue_depth: effect_queue_depth,
          alive: worker_thread&.alive? || false,
          active_timers: active_timer_count
        }
      }
    end

    def adapter_for(name)
      adapter_name = name || default_adapter
      adapter = adapters[adapter_name]
      return adapter if adapter

      raise AgentLoop::SensorRuntimeError.new(
        "Unknown sensor adapter: #{adapter_name}",
        code: :sensor_adapter_not_found,
        context: { sensor_id: instance.id, adapter: adapter_name }
      )
    end

    def schedule_event(delay_ms:, event: :tick)
      timer = Thread.new do
        sleep(delay_ms.to_f / 1000.0)
        event(event)
      rescue StandardError
        nil
      end

      mutex.synchronize { @timer_threads << timer }
      :ok
    end

    def deliver_signal(signal, target: nil)
      resolved_target = target || instance.context[:agent_ref] || instance.context['agent_ref']
      return :ok unless resolved_target

      if resolved_target.respond_to?(:cast)
        resolved_target.cast(signal)
        return :ok
      end

      server = AgentLoop::AgentServer.whereis(resolved_target)
      if server
        server.cast(signal)
        return :ok
      end

      raise AgentLoop::SensorRuntimeError.new(
        "Could not resolve agent_ref #{resolved_target.inspect}",
        code: :agent_ref_not_found,
        context: { sensor_id: instance.id, agent_ref: resolved_target }
      )
    end

    private

    attr_reader :sensor, :config, :registry, :max_event_queue_size, :max_effect_queue_size,
                :effect_executor, :event_mailbox, :effect_mailbox, :mutex, :completion_condition,
                :worker_thread, :adapters, :default_adapter

    def bootstrap!
      validated_config = instance.sensor_class.validate_config!(config)
      instance.metadata[:config] = validated_config

      raw = sensor.init(validated_config, context: instance.context)
      result = sensor.normalize_sensor_result(raw, current_state: instance.state, phase: :init)

      apply_result!(result)
      enqueue_result_effects(result)
      drain_effects
      instance.status = :idle
    rescue StandardError => e
      transition_to(:failed)
      instance.status = :failed
      instance.metadata[:last_error] = { code: :sensor_init_failed, message: e.message }
      raise e
    end

    def run_loop
      loop do
        envelope = event_mailbox.pop
        break if envelope == :__stop__

        decrement_event_depth
        process_event_envelope(envelope)
      end
    rescue StandardError => e
      transition_to(:failed)
      instance.status = :failed
      instance.metadata[:last_error] = { code: :sensor_server_failed, message: e.message }
      completion_condition.broadcast
      raise e
    ensure
      registry.unregister(instance.id)
      cancel_timers
      safely_terminate(:shutdown)
    end

    def process_event_envelope(envelope)
      transition_to(:processing_event)

      payload = { sensor_id: instance.id, sensor_class: instance.sensor_class.to_s }
      result = AgentLoop::Notifications.instrument_lifecycle('agent_loop.sensor.event', payload) do
        merged_context = (instance.context || {}).merge(envelope.context || {})
        raw = sensor.handle_event(envelope.event, instance.state, context: merged_context)
        sensor.normalize_sensor_result(raw, current_state: instance.state, phase: :handle_event)
      end

      apply_result!(result)
      enqueue_result_effects(result)
      transition_to(:draining_effects)
      failures = drain_effects
      raise failures.first if failures.any?

      fulfill_reply(envelope.reply, result: result)
    rescue StandardError => e
      transition_to(:failed)
      instance.status = :failed
      instance.metadata[:last_error] = { code: :sensor_event_failed, message: e.message }
      fulfill_reply(envelope.reply, error: e)
    ensure
      finalize_idle_state unless TERMINAL_STATUSES.include?(status)
      completion_condition.broadcast if TERMINAL_STATUSES.include?(status)
    end

    def apply_result!(result)
      if result.status == :error
        raise AgentLoop::SensorRuntimeError.new(
          result.error && result.error[:message] ? result.error[:message] : 'Sensor callback failed',
          code: result.error && result.error[:code] ? result.error[:code] : :sensor_callback_error,
          context: { sensor_id: instance.id, sensor_class: instance.sensor_class.to_s }
        )
      end

      instance.state = result.state
      instance.metadata[:last_error] = nil
    end

    def enqueue_result_effects(result)
      effects = AgentLoop::SensorEffects::Parser.parse_many(result.effects, raw_signals: result.signals)
      effects.each { |effect| enqueue_effect(effect) }
    end

    def enqueue_event(payload, context:, reply: nil)
      envelope = EventEnvelope.new(payload, context, reply)

      mutex.synchronize do
        raise QueueOverflow, "Event queue overflow for #{instance.id}" if @event_queue_depth >= max_event_queue_size

        @event_queue_depth += 1
      end

      event_mailbox << envelope
    end

    def enqueue_effect(effect)
      envelope = EffectEnvelope.new(effect)

      mutex.synchronize do
        if @effect_queue_depth >= max_effect_queue_size
          raise QueueOverflow,
                "Effect queue overflow for #{instance.id}"
        end

        @effect_queue_depth += 1
      end

      effect_mailbox << envelope
    end

    def drain_effects
      failures = []

      until effect_queue_depth.zero?
        begin
          envelope = effect_mailbox.pop
          decrement_effect_depth
          effect_executor.execute(envelope.effect, sensor_server: self)
        rescue StandardError => e
          failures << e
        end
      end

      failures
    end

    def finalize_idle_state
      transition_to(:idle)
      instance.status = :idle unless TERMINAL_STATUSES.include?(instance.status)
    end

    def safely_terminate(reason)
      sensor.terminate(reason, instance.state, context: instance.context)
    rescue StandardError
      nil
    end

    def fulfill_reply(reply, result: nil, error: nil)
      return unless reply

      reply.mutex.synchronize do
        reply.result = result
        reply.error = error
        reply.done = true
        reply.condition.broadcast
      end
    end

    def decrement_event_depth
      mutex.synchronize do
        @event_queue_depth -= 1 if @event_queue_depth.positive?
      end
    end

    def decrement_effect_depth
      mutex.synchronize do
        @effect_queue_depth -= 1 if @effect_queue_depth.positive?
      end
    end

    def event_queue_depth
      mutex.synchronize { @event_queue_depth }
    end

    def effect_queue_depth
      mutex.synchronize { @effect_queue_depth }
    end

    def transition_to(next_status)
      mutex.synchronize { @status = next_status }
    end

    def cancel_timers
      timers = mutex.synchronize do
        snapshot = @timer_threads.dup
        @timer_threads.clear
        snapshot
      end

      timers.each do |timer|
        timer.kill if timer.alive?
      end
    end

    def active_timer_count
      mutex.synchronize do
        @timer_threads.select!(&:alive?)
        @timer_threads.length
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
