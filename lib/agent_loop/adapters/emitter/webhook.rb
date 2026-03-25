# frozen_string_literal: true

require 'json'
require 'openssl'

module AgentLoop
  module Adapters
    module Emitter
      class Webhook
        def initialize(endpoint:, secret:, signature_header: 'X-Signature-SHA256',
                       timestamp_header: 'X-Signature-Timestamp', headers: {}, client: nil)
          @endpoint = endpoint
          @secret = secret
          @signature_header = signature_header
          @timestamp_header = timestamp_header
          @headers = headers
          @client = client || AgentLoop::Adapters::Emitter::Http::NetHttpClient.new
        end

        def emit(signal, target: nil)
          timestamp = Time.now.to_i.to_s
          payload = JSON.generate(signal.to_h)
          signature = OpenSSL::HMAC.hexdigest('SHA256', @secret, "#{timestamp}.#{payload}")
          merged_headers = @headers.merge(
            @timestamp_header => timestamp,
            @signature_header => signature
          )

          adapter = AgentLoop::Adapters::Emitter::Http.new(
            endpoint: target || @endpoint,
            headers: merged_headers,
            client: @client
          )

          adapter.emit(signal)
        end
      end
    end
  end
end
