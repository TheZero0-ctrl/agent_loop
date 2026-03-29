# frozen_string_literal: true

module AgentLoop
  class Supervisor
    ChildSpec = Struct.new(:id, :type, :start, :restart, :shutdown_timeout)

    SUPPORTED_STRATEGIES = %i[one_for_one].freeze
    SUPPORTED_CHILD_TYPES = %i[agent_server sensor_server].freeze
    SUPPORTED_RESTART_POLICIES = %i[permanent transient temporary].freeze

    def self.start_link(children:, strategy: :one_for_one, max_restarts: 3, max_seconds: 5,
                        monitor_interval: 0.05,
                        server_manager: AgentLoop::ServerManager.new,
                        sensor_manager: AgentLoop::SensorManager.new)
      new(
        children: children,
        strategy: strategy,
        max_restarts: max_restarts,
        max_seconds: max_seconds,
        monitor_interval: monitor_interval,
        server_manager: server_manager,
        sensor_manager: sensor_manager
      ).tap(&:start)
    end

    attr_reader :strategy

    def initialize(children:, strategy: :one_for_one, max_restarts: 3, max_seconds: 5,
                   monitor_interval: 0.05,
                   server_manager: AgentLoop::ServerManager.new,
                   sensor_manager: AgentLoop::SensorManager.new)
      @strategy = strategy.to_sym
      @max_restarts = Integer(max_restarts)
      @max_seconds = max_seconds.to_f
      @monitor_interval = monitor_interval.to_f
      @server_manager = server_manager
      @sensor_manager = sensor_manager
      @child_specs = normalize_children(children)
      @children = {}
      @child_order = []
      @restart_timestamps = []
      @mutex = Mutex.new
      @status = :stopped
      @monitor_thread = nil
      @stop_requested = false
      @last_error = nil

      validate_configuration!
    end

    def start
      mutex.synchronize do
        return self if @status == :running

        @status = :starting
        @stop_requested = false
      end

      child_specs.each { |spec| start_child(spec) }
      start_monitor_loop

      mutex.synchronize { @status = :running }
      self
    rescue StandardError => e
      mutex.synchronize do
        @status = :failed
        @last_error = { code: :supervisor_start_failed, message: e.message }
      end
      stop(reason: :start_failed, final_status: :failed)
      raise
    end

    def stop(reason: nil, final_status: :stopped)
      mutex.synchronize do
        return :ok if @status == :stopped

        @stop_requested = true
      end

      thread = monitor_thread
      if thread && thread != Thread.current
        thread.kill
        thread.join(0.2)
      end

      shutdown_children(reason: reason)

      mutex.synchronize do
        @status = final_status
      end

      :ok
    end

    def status
      mutex.synchronize { @status }
    end

    def snapshot
      mutex.synchronize do
        {
          status: @status,
          strategy: strategy,
          max_restarts: @max_restarts,
          max_seconds: @max_seconds,
          restart_count_window: restart_timestamps.length,
          last_error: @last_error,
          children: @child_order.filter_map { |id| child_snapshot(id) }
        }
      end
    end

    def which_children
      mutex.synchronize { @child_order.filter_map { |id| child_snapshot(id) } }
    end

    def whereis_child(id)
      mutex.synchronize { @children[id]&.fetch(:server, nil) }
    end

    def child_status(id)
      child = mutex.synchronize { @children[id] }
      return nil unless child

      child_server_status(child[:server])
    end

    def restart_child(id)
      child = mutex.synchronize { @children[id] }
      raise ArgumentError, "Unknown child id #{id}" unless child

      stop_child(child, reason: :manual_restart)
      restart_child_entry(child, reason: :manual_restart)
      :ok
    end

    private

    attr_reader :max_restarts, :max_seconds, :monitor_interval, :server_manager, :sensor_manager,
                :child_specs, :children, :child_order, :restart_timestamps, :mutex, :monitor_thread

    def validate_configuration!
      raise ArgumentError, "Unsupported strategy: #{strategy}" unless SUPPORTED_STRATEGIES.include?(strategy)
      raise ArgumentError, 'max_restarts must be >= 0' if max_restarts.negative?
      raise ArgumentError, 'max_seconds must be > 0' if max_seconds <= 0
    end

    def normalize_children(children_input)
      Array(children_input).map { |entry| normalize_child_spec(entry) }
    end

    def normalize_child_spec(entry)
      spec = if entry.is_a?(ChildSpec)
               entry
             else
               ChildSpec.new(entry.fetch(:id), entry.fetch(:type), entry[:start], entry[:restart],
                             entry[:shutdown_timeout])
             end
      spec.id = spec.id.to_s
      spec.type = spec.type.to_sym
      spec.start = (spec.start || {}).dup
      spec.restart = (spec.restart || :permanent).to_sym
      spec.shutdown_timeout = (spec.shutdown_timeout || 1).to_f

      raise ArgumentError, "Unsupported child type: #{spec.type}" unless SUPPORTED_CHILD_TYPES.include?(spec.type)
      unless SUPPORTED_RESTART_POLICIES.include?(spec.restart)
        raise ArgumentError, "Unsupported restart policy: #{spec.restart}"
      end

      spec
    end

    def start_child(spec)
      server = case spec.type
               when :agent_server
                 start_agent_child(spec)
               when :sensor_server
                 start_sensor_child(spec)
               else
                 raise ArgumentError, "Unsupported child type: #{spec.type}"
               end

      mutex.synchronize do
        @children[spec.id] = { spec: spec, server: server }
        @child_order << spec.id unless @child_order.include?(spec.id)
      end

      server
    end

    def start_agent_child(spec)
      args = spec.start.dup
      args[:id] ||= spec.id
      server_manager.start(**args)
    end

    def start_sensor_child(spec)
      args = spec.start.dup
      args[:id] ||= spec.id
      sensor_manager.start(**args)
    end

    def start_monitor_loop
      @monitor_thread = Thread.new do
        loop do
          break if stop_requested?

          monitor_children
          sleep(monitor_interval)
        end
      rescue StandardError => e
        mutex.synchronize do
          @status = :failed
          @last_error = { code: :supervisor_monitor_failed, message: e.message }
        end
        stop(reason: :monitor_failed, final_status: :failed)
      end
      @monitor_thread.name = 'agent-loop-supervisor-monitor' if @monitor_thread.respond_to?(:name=)
    end

    def stop_requested?
      mutex.synchronize { @stop_requested }
    end

    def monitor_children
      entries = mutex.synchronize { @children.values.map(&:dup) }

      entries.each do |entry|
        reason = child_exit_reason(entry[:server])
        next unless reason

        handle_child_exit(entry, reason: reason)
      end
    end

    def child_exit_reason(server)
      status = child_server_status(server)
      return :failed if status == :failed
      return :stopped if status == :stopped
      return :crashed unless child_alive?(server)

      nil
    end

    def child_alive?(server)
      return false unless server
      return true unless server.respond_to?(:snapshot)

      snapshot = server.snapshot
      server_info = snapshot[:server] || {}
      server_info.fetch(:alive, true)
    rescue StandardError
      false
    end

    def child_server_status(server)
      return nil unless server
      return server.status if server.respond_to?(:status)

      nil
    rescue StandardError
      :failed
    end

    def handle_child_exit(entry, reason:)
      spec = entry.fetch(:spec)
      return if stop_requested?

      restart = should_restart?(spec.restart, reason)
      unless restart
        remove_child(spec.id)
        return
      end

      unless allowed_to_restart?
        mutex.synchronize do
          @last_error = {
            code: :restart_intensity_exceeded,
            message: "Restart intensity exceeded for child #{spec.id}",
            child_id: spec.id,
            reason: reason
          }
        end
        stop(reason: :restart_intensity_exceeded, final_status: :failed)
        return
      end

      restart_child_entry(entry, reason: reason)
    end

    def should_restart?(policy, reason)
      case policy
      when :permanent
        true
      when :transient
        !%i[stopped normal shutdown].include?(reason)
      when :temporary
        false
      end
    end

    def allowed_to_restart?
      now = monotonic_now
      window_start = now - max_seconds

      mutex.synchronize do
        @restart_timestamps.reject! { |timestamp| timestamp < window_start }
        return false if @restart_timestamps.length >= max_restarts

        @restart_timestamps << now
      end

      true
    end

    def restart_child_entry(entry, reason:)
      spec = entry.fetch(:spec)
      stop_child(entry, reason: reason)
      start_child(spec)
    end

    def stop_child(entry, reason:)
      spec = entry.fetch(:spec)
      server = entry[:server]
      return unless server

      stopper = Thread.new do
        case spec.type
        when :agent_server
          server_manager.stop(server, reason: reason)
        when :sensor_server
          sensor_manager.stop(server, reason: reason)
        end
      end

      timeout = spec.shutdown_timeout
      stopper.join(timeout)
      stopper.kill if stopper.alive?
    rescue StandardError
      nil
    end

    def remove_child(id)
      mutex.synchronize do
        @children.delete(id)
        @child_order.delete(id)
      end
    end

    def shutdown_children(reason:)
      entries = mutex.synchronize { @child_order.reverse.filter_map { |id| @children[id] } }
      entries.each { |entry| stop_child(entry, reason: reason || :shutdown) }

      mutex.synchronize do
        @children.clear
        @child_order.clear
      end
    end

    def child_snapshot(id)
      entry = @children[id]
      return nil unless entry

      server = entry[:server]
      {
        id: id,
        type: entry[:spec].type,
        restart: entry[:spec].restart,
        status: child_server_status(server),
        alive: child_alive?(server)
      }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
