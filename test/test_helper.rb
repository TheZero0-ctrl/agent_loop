# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'agent_loop'

unless defined?(RubyLLM::Tool)
  module RubyLLM
    class Tool
      class << self
        attr_reader :_description, :_params

        def description(text = nil)
          return @_description unless text

          @_description = text
        end

        def params(schema = nil)
          @_params = schema
        end
      end

      def call(args)
        execute(**args.transform_keys(&:to_sym))
      end
    end
  end
end

require 'minitest/autorun'
