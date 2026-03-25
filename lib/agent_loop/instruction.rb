# frozen_string_literal: true

module AgentLoop
  class Instruction
    attr_reader :action, :params, :context, :opts, :meta

    def self.new!(attrs)
      action = attrs.fetch(:action)
      new(
        action: action,
        params: attrs.fetch(:params, {}),
        context: attrs.fetch(:context, {}),
        opts: attrs.fetch(:opts, {}),
        meta: attrs.fetch(:meta, {})
      )
    end

    def initialize(action:, params: {}, context: {}, opts: {}, meta: {})
      @action = action
      @params = params
      @context = context
      @opts = opts
      @meta = meta
    end

    def with(action: self.action, params: self.params, context: self.context, opts: self.opts, meta: self.meta)
      self.class.new(action: action, params: params, context: context, opts: opts, meta: meta)
    end

    def self.normalize(input)
      return [input] if input.is_a?(Instruction)
      return [Instruction.new(action: input)] if action_class?(input)

      if tuple_instruction?(input)
        action = input[0]
        params = input[1] || {}
        context = input[2] || {}
        opts = input[3] || {}
        meta = input[4] || {}
        return [Instruction.new(action: action, params: params, context: context, opts: opts, meta: meta)]
      end

      return input.flat_map { |entry| normalize(entry) } if input.is_a?(Array)

      [Instruction.new(action: input, params: {})]
    end

    def self.tuple_instruction?(input)
      return false unless input.is_a?(Array)
      return false if input.empty?

      first = input[0]
      return false unless action_class?(first) || first.is_a?(Symbol) || first.is_a?(String)

      true
    end

    def self.action_class?(value)
      value.is_a?(Class) && value <= AgentLoop::Action
    end
  end
end
