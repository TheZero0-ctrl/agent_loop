# frozen_string_literal: true

require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect(
  "ai" => "AI"
)
loader.setup

module AgentLoop
  class Error < StandardError; end
end
