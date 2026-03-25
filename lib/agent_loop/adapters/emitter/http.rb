# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module AgentLoop
  module Adapters
    module Emitter
      class Http
        class NetHttpClient
          def request(uri:, method:, headers:, body:, open_timeout:, read_timeout:)
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: open_timeout,
                                                read_timeout: read_timeout) do |http|
              request_class = method.to_s.downcase == "get" ? Net::HTTP::Get : Net::HTTP::Post
              request = request_class.new(uri)
              headers.each { |key, value| request[key] = value }
              request.body = body unless method.to_s.downcase == "get"
              response = http.request(request)
              { status: response.code.to_i, body: response.body.to_s, headers: response.to_hash }
            end
          end
        end

        def initialize(endpoint: nil, method: :post, headers: {}, open_timeout: 5, read_timeout: 10,
                       client: NetHttpClient.new)
          @endpoint = endpoint
          @method = method
          @headers = headers
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @client = client
        end

        def emit(signal, target: nil)
          uri = resolve_uri(target)
          payload = JSON.generate(signal.to_h)
          headers = {
            "Content-Type" => signal.datacontenttype,
            "X-Signal-Type" => signal.type,
            "X-Signal-Id" => signal.id
          }.merge(@headers)

          @client.request(
            uri: uri,
            method: @method,
            headers: headers,
            body: payload,
            open_timeout: @open_timeout,
            read_timeout: @read_timeout
          )
        end

        private

        def resolve_uri(target)
          endpoint = target || @endpoint
          raise ArgumentError, "HTTP emitter endpoint is required" if endpoint.nil?

          URI.parse(endpoint)
        end
      end
    end
  end
end
