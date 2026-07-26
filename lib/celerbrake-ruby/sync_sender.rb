module Celerbrake
  # Responsible for sending data to Celerbrake synchronously via PUT or POST
  # methods. Supports proxies.
  #
  # @see AsyncSender
  # @api private
  # @since v1.0.0
  class SyncSender
    # @return [String] body for HTTP requests
    CONTENT_TYPE = 'application/json'.freeze

    # @return [Array<Integer>] response codes that are good to be backlogged
    # @since v6.2.0
    BACKLOGGABLE_STATUS_CODES = [
      Response::BAD_REQUEST,
      Response::FORBIDDEN,
      Response::ENHANCE_YOUR_CALM,
      Response::REQUEST_TIMEOUT,
      Response::CONFLICT,
      Response::TOO_MANY_REQUESTS,
      Response::INTERNAL_SERVER_ERROR,
      Response::BAD_GATEWAY,
      Response::GATEWAY_TIMEOUT,
    ].freeze

    include Loggable

    # @param [Symbol] method HTTP method to use to send payload
    def initialize(method = :post)
      @config = Celerbrake::Config.instance
      @method = method
      # Rate limiting is tracked per endpoint (and this sender is already
      # per-notifier: errors, performance and deploys own separate senders).
      # A 429 minted for one destination — possibly by an intermediary that
      # knows nothing about the others — must not silence the rest.
      @rate_limit = RateLimit.new
      @backlog = Backlog.new(self) if @config.backlog
    end

    # Sends a POST or PUT request to the given +endpoint+ with the +data+ payload.
    #
    # @param [#to_json] data
    # @param [URI::HTTPS] endpoint
    # @return [Hash{String=>String}] the parsed HTTP response
    def send(data, promise, endpoint = @config.error_endpoint)
      return promise if rate_limited_ip?(endpoint, promise)

      req = build_request(endpoint, data)
      return promise if missing_body?(req, promise)

      begin
        response = build_https(endpoint).request(req)
      rescue StandardError => ex
        reason = "#{LOG_LABEL} HTTP error: #{ex}"
        logger.error(reason)
        return promise.reject(reason)
      end

      parsed_resp = Response.parse(response)
      handle_rate_limit(parsed_resp, endpoint)
      @backlog << [data, endpoint] if add_to_backlog?(parsed_resp)

      return promise.reject(parsed_resp['error']) if parsed_resp.key?('error')

      promise.resolve(parsed_resp)
    end

    # Tells when the rate-limit suppression for +endpoint+ expires. Exposed so
    # that an operator (or an agent asking "why did this app go quiet?") can
    # see that reporting is currently suppressed and until when — a silently
    # dropped notice is otherwise undetectable from inside the app.
    #
    # @param [URI::HTTPS, String] endpoint
    # @return [Time, nil] when sends resume, or nil when not suppressed
    def rate_limit_reset(endpoint = @config.error_endpoint)
      @rate_limit.reset_at(endpoint)
    end

    # @param [URI::HTTPS, String] endpoint
    # @return [Boolean] whether sends to +endpoint+ are currently suppressed
    #   by a 429 backoff
    def rate_limited?(endpoint = @config.error_endpoint)
      @rate_limit.suppressed?(endpoint)
    end

    # @return [Integer] how many payloads this sender has dropped because the
    #   destination was rate limiting it (since the sender was created)
    def rate_limited_drops
      @rate_limit.drops
    end

    # Closes all the resources that this sender has allocated.
    #
    # @return [void]
    # @since v6.2.0
    def close
      @backlog.close
    end

    private

    def build_https(uri)
      Net::HTTP.new(uri.host, uri.port, *proxy_params).tap do |https|
        https.use_ssl = uri.is_a?(URI::HTTPS)
        # Always bound the request: Net::HTTP's 60s defaults would let an
        # unreachable server pin the single worker thread per notice while
        # the queue blackholes everything behind it.
        https.open_timeout = @config.open_timeout
        https.read_timeout = @config.read_timeout
        if https.respond_to?(:write_timeout=) # Ruby >= 2.6
          https.write_timeout = @config.write_timeout
        end
      end
    end

    def build_request(uri, data)
      req =
        if @method == :put
          Net::HTTP::Put.new(uri.request_uri)
        else
          Net::HTTP::Post.new(uri.request_uri)
        end

      build_request_body(req, data)
    end

    def build_request_body(req, data)
      req.body = data.to_json

      req['Authorization'] = "Bearer #{@config.project_key}"
      req['Content-Type'] = CONTENT_TYPE
      req['User-Agent'] =
        "#{Celerbrake::NOTIFIER_INFO[:name]}/#{Celerbrake::CELERBRAKE_RUBY_VERSION} " \
        "Ruby/#{RUBY_VERSION}"

      req
    end

    # Records the backoff window Response computed for this endpoint. The
    # window is already clamped to Response::MAX_RATE_LIMIT_DELAY, so a
    # hostile or fat-fingered Retry-After cannot blind the app for a shift.
    #
    # @return [void]
    def handle_rate_limit(parsed_resp, endpoint)
      return unless parsed_resp.key?('rate_limit_reset')

      @rate_limit.suppress(endpoint, parsed_resp['rate_limit_reset'])
    end

    def add_to_backlog?(parsed_resp)
      return unless @backlog
      return unless parsed_resp.key?('code')

      BACKLOGGABLE_STATUS_CODES.include?(parsed_resp['code'])
    end

    def proxy_params
      return unless @config.proxy.key?(:host)

      [@config.proxy[:host], @config.proxy[:port], @config.proxy[:user],
       @config.proxy[:password]]
    end

    def rate_limited_ip?(endpoint, promise)
      reset = @rate_limit.reset_at(endpoint)
      return false unless reset

      promise.reject("#{LOG_LABEL} IP is rate limited")
      # Never a silent drop: counted and (throttled) logged, so an operator or
      # agent can see that reporting is suppressed and until when.
      @rate_limit.note_drop(endpoint, reset)
      true
    end

    def missing_body?(req, promise)
      missing = req.body.nil?

      if missing
        reason = "#{LOG_LABEL} data was not sent because of missing body"
        logger.error(reason)
        promise.reject(reason)
      end

      missing
    end
  end
end
