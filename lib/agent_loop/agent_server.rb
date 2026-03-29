# frozen_string_literal: true

require 'securerandom'

module AgentLoop
  class AgentServer
    class QueueOverflow < StandardError
    end

    CallReply = Struct.new(:mutex, :condition, :done, :result, :error)
    SignalEnvelope = Struct.new(:signal, :context, :reply)
    EffectEnvelope = Struct.new(:effect, :context)

    DEFAULT_MAX_QUEUE_SIZE = 10_000
    TERMINAL_STATUSES = %i[completed failed stopped].freeze
    PARENT_DEATH_SIGNAL = 'agent_loop.parent.orphaned'
    INTERNAL_SIGNAL_TYPES = [PARENT_DEATH_SIGNAL, /^agent_loop\.child\./].freeze

    class << self
      def start(agent: nil, runtime: nil, instance: nil, agent_class: nil, agent_module: nil, id: nil,
                initial_state: nil,
                registry: AgentLoop::Registry, max_signal_queue_size: DEFAULT_MAX_QUEUE_SIZE,
                max_effect_queue_size: DEFAULT_MAX_QUEUE_SIZE)
        runtime ||= AgentLoop.runtime
        resolved_instance = resolve_instance(
          agent: agent,
          instance: instance,
          agent_class: agent_class,
          agent_module: agent_module,
          id: id,
          initial_state: initial_state
        )

        new(
          runtime: runtime,
          instance: resolved_instance,
          registry: registry,
          max_signal_queue_size: max_signal_queue_size,
          max_effect_queue_size: max_effect_queue_size
        ).tap(&:start)
      end

      alias start_link start

      def whereis(id, registry: AgentLoop::Registry)
        registry.whereis(id)
      end

      def deliver_scheduled_signal(payload:, runtime:, registry: AgentLoop::Registry)
        instance_id = payload.fetch('instance_id')
        signal = AgentLoop::Signal.from_h(payload.fetch('signal'))
        context = payload.fetch('meta', {})

        live_server = whereis(instance_id, registry: registry)
        return live_server.call(signal, context: context) if live_server

        agent_class = constantize_agent_class(payload.fetch('agent_class'))
        instance = AgentLoop::Instance.new(agent_class: agent_class, id: instance_id)
        runtime.call(instance, signal, context: context)
      end

      private

      def resolve_instance(agent:, instance:, agent_class:, agent_module:, id:, initial_state:)
        provided_instance = instance || (agent if agent.is_a?(AgentLoop::Instance))
        return provided_instance if provided_instance

        resolved_agent_class =
          if agent_class
            agent_class
          elsif agent_module
            agent_module
          elsif agent.is_a?(Class) || agent.is_a?(Module)
            agent
          else
            raise ArgumentError, 'start requires agent:, agent_class:, or instance:'
          end

        derived_id = id || agent_id_from(agent) || SecureRandom.uuid
        derived_state = initial_state || agent_state_from(agent)

        AgentLoop::Instance.new(
          agent_class: resolved_agent_class,
          id: derived_id,
          state: derived_state
        )
      end

      def agent_id_from(agent)
        return unless agent
        return unless agent.respond_to?(:id)

        agent.id
      end

      def agent_state_from(agent)
        return unless agent
        return unless agent.respond_to?(:state)

        agent.state
      end

      def constantize_agent_class(name)
        return name if name.is_a?(Class)

        name.to_s.split('::').reject(&:empty?).reduce(Object) do |scope, const_name|
          scope.const_get(const_name)
        end
      end
    end

    attr_reader :runtime, :instance

    def initialize(runtime:, instance:, registry: AgentLoop::Registry,
                   max_signal_queue_size: DEFAULT_MAX_QUEUE_SIZE,
                   max_effect_queue_size: DEFAULT_MAX_QUEUE_SIZE)
      @runtime = runtime
      @instance = instance
      @registry = registry
      @max_signal_queue_size = max_signal_queue_size
      @max_effect_queue_size = max_effect_queue_size
      @signal_mailbox = Queue.new
      @effect_mailbox = Queue.new
      @mutex = Mutex.new
      @completion_condition = ConditionVariable.new
      @signal_queue_depth = 0
      @effect_queue_depth = 0
      @status = instance.status || :idle
      @worker_thread = nil
    end

    def start
      mutex.synchronize do
        return self if @worker_thread&.alive?

        registry.register(instance.id, self)
        @worker_thread = Thread.new { run_loop }
        @worker_thread.name = "agent-loop-server-#{instance.id}" if @worker_thread.respond_to?(:name=)
      end

      self
    end

    def call(signal, context: {})
      start
      reply = CallReply.new(Mutex.new, ConditionVariable.new, false)
      enqueue_signal(signal, context: context, reply: reply)

      reply.mutex.synchronize do
        reply.condition.wait(reply.mutex) until reply.done
      end

      raise reply.error if reply.error

      reply.result
    end

    def cast(signal, context: {})
      start
      enqueue_signal(signal, context: context)
      :ok
    end

    def stop(reason: nil)
      stop_managed_children

      mutex.synchronize do
        return :ok if @status == :stopped

        instance.status = :stopped
        instance.metadata[:stop_reason] = reason if reason
        @status = :stopped
        completion_condition.broadcast
      end

      signal_mailbox << :__stop__
      worker_thread&.join
      notify_parent_of_terminal_status
      registry.unregister(instance.id)
      :ok
    end

    def status
      mutex.synchronize { @status }
    end

    def state
      mutex.synchronize { instance.state }
    end

    def completed?
      status == :completed
    end

    def failed?
      status == :failed
    end

    def stopped?
      status == :stopped
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

    def accepts_signal?(signal, context: {})
      route = runtime.router.resolve(instance.agent_class, signal, strategy: runtime.strategy, context: context)
      !route.nil?
    rescue AgentLoop::Router::RouteNotFound, AgentLoop::RuntimeError, StandardError
      false
    end

    def snapshot
      {
        runtime: runtime.snapshot(instance),
        instance: {
          id: instance.id,
          status: instance.status,
          state: instance.state,
          state_version: instance.metadata[:state_version],
          last_error: instance.metadata[:last_error],
          children: instance.children.keys,
          parent_id: instance.metadata[:parent_id],
          on_parent_death: instance.metadata[:on_parent_death]
        },
        server: {
          status: status,
          signal_queue_depth: signal_queue_depth,
          effect_queue_depth: effect_queue_depth,
          alive: worker_thread&.alive? || false
        }
      }
    end

    private

    attr_reader :registry, :max_signal_queue_size, :max_effect_queue_size, :signal_mailbox,
                :effect_mailbox, :mutex, :completion_condition, :worker_thread

    def run_loop
      loop do
        envelope = signal_mailbox.pop
        break if envelope == :__stop__

        decrement_signal_depth
        process_signal_envelope(envelope)
      end
    rescue StandardError => e
      transition_to(:failed)
      instance.metadata[:last_error] = { code: :agent_server_failed, message: e.message }
      completion_condition.broadcast
      raise e
    ensure
      registry.unregister(instance.id)
    end

    def process_signal_envelope(envelope)
      transition_to(:processing_signal)
      apply_internal_signal_updates(envelope.signal)
      result = if internal_signal_without_route?(envelope.signal, context: envelope.context)
                 AgentLoop::Result.new(state: instance.state, effects: [], status: :ok)
               else
                 runtime.process_signal(instance, envelope.signal, context: envelope.context)
               end

      Array(result.effects).each do |effect|
        enqueue_effect(effect, context: envelope.context)
      end

      transition_to(:draining_effects)
      effect_failures = drain_effects
      final_result = runtime.finalize_result(result, effect_failures)
      apply_terminal_status(final_result)
      fulfill_reply(envelope.reply, result: final_result)
    rescue StandardError => e
      transition_to(:failed)
      instance.status = :failed
      instance.metadata[:last_error] = { code: :agent_server_failed, message: e.message }
      fulfill_reply(envelope.reply, error: e)
    ensure
      finalize_idle_state unless TERMINAL_STATUSES.include?(status)
      notify_parent_of_terminal_status if TERMINAL_STATUSES.include?(status)
      completion_condition.broadcast if TERMINAL_STATUSES.include?(status)
    end

    def enqueue_signal(signal, context:, reply: nil)
      envelope = SignalEnvelope.new(signal, context, reply)

      mutex.synchronize do
        raise QueueOverflow, "Signal queue overflow for #{instance.id}" if @signal_queue_depth >= max_signal_queue_size

        @signal_queue_depth += 1
      end

      signal_mailbox << envelope
    end

    def enqueue_effect(effect, context: {})
      envelope = EffectEnvelope.new(effect, context)

      mutex.synchronize do
        raise QueueOverflow, "Effect queue overflow for #{instance.id}" if @effect_queue_depth >= max_effect_queue_size

        @effect_queue_depth += 1
      end

      effect_mailbox << envelope
    end

    def drain_effects
      failures = []

      until effect_queue_depth.zero?
        envelope = effect_mailbox.pop
        decrement_effect_depth
        failures.concat(runtime.execute_effects([envelope.effect], instance: instance, context: envelope.context))
      end

      failures
    end

    def apply_terminal_status(result)
      if result.status == :error
        transition_to(:failed)
        instance.status = :failed
      else
        synchronize_status_from_instance
      end
    end

    def synchronize_status_from_instance
      derived_status = case instance.status
                       when :completed, :failed, :stopped
                         instance.status
                       else
                         :idle
                       end

      transition_to(derived_status)
    end

    def finalize_idle_state
      transition_to(:idle)
      instance.status = :idle unless TERMINAL_STATUSES.include?(instance.status)
    end

    def stop_managed_children
      child_entries.each_value do |child_entry|
        child_server = child_entry[:server]
        next unless child_server

        case child_entry[:on_parent_death]
        when :continue
          next
        when :emit_orphan
          if child_server != self && child_server.accepts_signal?(build_parent_orphaned_signal)
            child_server.cast(build_parent_orphaned_signal)
          end
        else
          child_server.stop(reason: :parent_stopped) if child_server != self
        end
      end
    end

    def child_entries
      instance.children.each_with_object({}) do |(key, value), memo|
        memo[key] = value.is_a?(Hash) ? value : { id: key, server: nil, on_parent_death: :stop }
      end
    end

    def build_parent_orphaned_signal
      AgentLoop::Signal.new(
        type: PARENT_DEATH_SIGNAL,
        source: "agent://#{instance.id}",
        data: {
          parent_id: instance.id
        }
      )
    end

    def notify_parent_of_terminal_status
      parent_id = instance.metadata[:parent_id]
      return unless parent_id
      return if instance.metadata[:last_parent_notification_status] == status

      parent_server = self.class.whereis(parent_id, registry: registry)
      return unless parent_server

      instance.metadata[:last_parent_notification_status] = status
      parent_server.cast(build_child_lifecycle_signal)
    end

    def build_child_lifecycle_signal
      AgentLoop::Signal.new(
        type: "agent_loop.child.#{status}",
        source: "agent://#{instance.id}",
        data: {
          parent_id: instance.metadata[:parent_id],
          child_id: instance.id,
          child_class: instance.agent_class.to_s,
          tag: instance.metadata[:parent_tag],
          status: status
        }
      )
    end

    def apply_internal_signal_updates(signal)
      return unless signal.type.start_with?('agent_loop.child.')

      data = signal.data || {}
      tag = data[:tag] || data['tag']
      return unless tag

      entry = instance.children[tag] || {}
      entry = entry.dup if entry.is_a?(Hash)
      entry[:id] ||= data[:child_id] || data['child_id']
      entry[:status] = signal.type.split('.').last.to_sym
      instance.children[tag] = entry
    end

    def internal_signal_without_route?(signal, context: {})
      internal_signal?(signal.type) && !accepts_signal?(signal, context: context)
    end

    def internal_signal?(signal_type)
      INTERNAL_SIGNAL_TYPES.any? do |pattern|
        pattern.is_a?(Regexp) ? signal_type.match?(pattern) : signal_type == pattern
      end
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

    def decrement_signal_depth
      mutex.synchronize do
        @signal_queue_depth -= 1 if @signal_queue_depth.positive?
      end
    end

    def decrement_effect_depth
      mutex.synchronize do
        @effect_queue_depth -= 1 if @effect_queue_depth.positive?
      end
    end

    def signal_queue_depth
      mutex.synchronize { @signal_queue_depth }
    end

    def effect_queue_depth
      mutex.synchronize { @effect_queue_depth }
    end

    def transition_to(next_status)
      mutex.synchronize { @status = next_status }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
