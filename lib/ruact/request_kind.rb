# frozen_string_literal: true

module Ruact
  # Internal — how a request says what it wants from ruact. Two questions, with
  # different answers on purpose:
  #
  # - {.flight?} — does the client want a Flight body back rather than an HTML
  #   document? Either header says so: `Accept: text/x-component` (any Flight
  #   client) or `Ruact-Request: 1` (ruact's router, which sends both).
  # - {.from_router?} — did ruact's own router send it? Only `Ruact-Request: 1`
  #   says that; {NavigationBoundary} answers router navigations to pages that
  #   are not ruact's, and must not answer anyone else.
  module RequestKind
    # The Flight media type, as requested and as answered.
    FLIGHT_MIME = "text/x-component"
    # The header ruact's router adds to every request it makes.
    ROUTER_HEADER = "Ruact-Request"
    ROUTER_ENV = "HTTP_RUACT_REQUEST"

    # @param request [ActionDispatch::Request]
    def self.flight?(request)
      request.headers["Accept"]&.include?(FLIGHT_MIME) || request.headers[ROUTER_HEADER] == "1"
    end

    # @param env [Hash] the Rack env (it runs before Rails builds a request)
    def self.from_router?(env)
      env[ROUTER_ENV] == "1"
    end

    # Which header made {.flight?} true, as the request sent it — for a log
    # line that names it.
    def self.flight_signal(request)
      request.headers["Accept"].to_s.include?(FLIGHT_MIME) ? "Accept: #{FLIGHT_MIME}" : "#{ROUTER_HEADER}: 1"
    end
  end
end
