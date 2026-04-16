# frozen_string_literal: true

module AgentLoop
  class Router
    class RouteNotFound < StandardError; end
    Route = Struct.new(:pattern, :target, :priority, :source, :index)
    STRATEGY_TICK_ACTION = :__strategy_tick__

    STRATEGY_PRIORITY = 50
    AGENT_PRIORITY = 0
    PLUGIN_PRIORITY = -10

    def instruction_for(agent_class, signal, strategy: nil, context: {})
      route = resolve(agent_class, signal, strategy: strategy, context: context)
      raise RouteNotFound, "No route for signal type: #{signal.type}" unless route

      action, params = target_to_instruction(route.target, signal)

      Instruction.new(
        action: action,
        params: params,
        meta: {
          signal_id: signal.id,
          signal_type: signal.type,
          route_pattern: route.pattern,
          route_priority: route.priority,
          route_source: route.source
        }
      )
    end

    def resolve(agent_class, signal, strategy: nil, context: {})
      routes = build_routes(agent_class, strategy: strategy, context: context)
      candidates = routes.select { |route| match_pattern?(route.pattern, signal.type) }
      candidates.max_by { |route| rank(route) }
    end

    private

    def build_routes(agent_class, strategy:, context:)
      all = []
      index = 0

      append_routes(all, normalize_strategy_routes(strategy, agent_class, context), :strategy, STRATEGY_PRIORITY) do
        index += 1
        index - 1
      end
      append_routes(all, normalize_agent_routes(agent_class, context), :agent, AGENT_PRIORITY) do
        index += 1
        index - 1
      end
      append_routes(all, normalize_plugin_routes(agent_class, context), :plugin, PLUGIN_PRIORITY) do
        index += 1
        index - 1
      end

      all
    end

    def append_routes(all, specs, source, default_priority)
      Array(specs).each do |spec|
        pattern, target, priority = normalize_route_spec(spec, default_priority)
        next if pattern.nil? || target.nil?

        all << Route.new(pattern, target, priority, source, yield)
      end
    end

    def normalize_strategy_routes(strategy, agent_class, context)
      return [] unless strategy
      return [] unless strategy.respond_to?(:signal_routes)

      invoke_route_provider(strategy, context.merge(agent_class: agent_class, strategy: strategy))
    end

    def normalize_agent_routes(agent_class, context)
      if agent_class.respond_to?(:signal_routes)
        invoke_route_provider(agent_class, context.merge(agent_class: agent_class))
      else
        Array(agent_class.routes).map { |pattern, target| [pattern, target] }
      end
    end

    def normalize_plugin_routes(agent_class, context)
      return [] unless agent_class.respond_to?(:plugin_signal_routes)

      invoke_route_provider(agent_class, context.merge(agent_class: agent_class), method_name: :plugin_signal_routes)
    end

    def invoke_route_provider(provider, context, method_name: :signal_routes)
      method = provider.method(method_name)
      if method.arity.zero?
        method.call
      else
        method.call(context)
      end
    rescue ArgumentError
      []
    end

    def normalize_route_spec(spec, default_priority)
      case spec
      when Array
        if spec.size >= 3 && spec[2].is_a?(Integer)
          [spec[0].to_s, spec[1], spec[2]]
        else
          [spec[0].to_s, spec[1], default_priority]
        end
      when Hash
        [spec.fetch(:pattern).to_s, spec.fetch(:target), spec.fetch(:priority, default_priority)]
      else
        [nil, nil, default_priority]
      end
    end

    def target_to_instruction(target, signal)
      return [target[1], signal.data] if target.is_a?(Array) && target.length == 2 && target[0] == :strategy_cmd

      return [STRATEGY_TICK_ACTION, signal.data] if target == :strategy_tick

      if target.is_a?(Array) && target.size == 2 && target[1].is_a?(Hash)
        [target[0], target[1].merge(signal.data || {})]
      else
        [target, signal.data]
      end
    end

    def rank(route)
      exact, single_wildcards, multi_wildcards, segments = specificity(route.pattern)
      [route.priority, exact, -multi_wildcards, -single_wildcards, segments, -route.index]
    end

    def specificity(pattern)
      parts = pattern.to_s.split('.')
      exact = parts.count { |part| part != '*' && part != '**' }
      single_wildcards = parts.count('*')
      multi_wildcards = parts.count('**')
      [exact, single_wildcards, multi_wildcards, parts.length]
    end

    def match_pattern?(pattern, type)
      pattern_parts = pattern.to_s.split('.')
      type_parts = type.to_s.split('.')
      pattern_match?(pattern_parts, type_parts)
    end

    def pattern_match?(pattern_parts, type_parts)
      return true if pattern_parts.empty? && type_parts.empty?
      return false if pattern_parts.empty?

      head = pattern_parts.first

      if head == '**'
        return true if pattern_parts.length == 1

        (0..type_parts.length).any? do |offset|
          pattern_match?(pattern_parts[1..], type_parts[offset..] || [])
        end
      end

      return false if type_parts.empty?
      return pattern_match?(pattern_parts[1..], type_parts[1..]) if head == '*' || head == type_parts.first

      false
    end
  end
end
