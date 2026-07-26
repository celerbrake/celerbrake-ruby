module Celerbrake
  # Tracks the 429 backoff windows of one sender, per endpoint, and makes the
  # resulting suppression observable.
  #
  # Two properties matter here:
  #
  # 1. **Bounded blast radius.** A 429 can be minted by any intermediary — a
  #    proxy, a WAF, a CDN, a misconfigured load balancer — that knows nothing
  #    about the other endpoints a sender talks to. A backoff therefore applies
  #    to the endpoint that asked for it, not to everything the sender sends.
  #    (Errors, performance and deploys already use separate senders.)
  # 2. **Observability.** While suppressed, payloads are dropped, and a silent
  #    drop is undetectable from inside the app. Drops are counted and logged
  #    (throttled), and the window is queryable, so an operator or an agent can
  #    tell that reporting is paused and until when.
  #
  # @api private
  class RateLimit
    include Loggable

    # @return [Integer] how long (in seconds) to back off after a 429 that
    #   carries no usable header — and the value substituted for any header
    #   we refuse to trust (malformed, negative, oversized, stale). Without a
    #   fallback the client would hot-retry a rate-limiting server on every
    #   notice.
    DEFAULT_DELAY = 60

    # @return [Integer] the longest backoff (in seconds) the notifier will
    #   honor from a 429, no matter what the response asks for.
    #
    #   A 429 can be minted by anything on the path — a proxy, a WAF, a CDN, a
    #   misconfigured load balancer — not only by Celerbrake, and whatever it
    #   says is obeyed by a client that is *inside the customer's app*. While
    #   suppressed the notifier drops notices rather than queueing them, so an
    #   over-long backoff is permanent data loss: the app goes dark exactly
    #   when its operator believes it is reporting.
    #
    #   15 minutes is the compromise. Celerbrake rate limits per minute (the
    #   429 is documented as "over 10k/min notices"), so every legitimate
    #   relief window is minute-scale — 15 consecutive windows is far more
    #   relief than a shedding server needs, and it also covers burst quotas
    #   and CDN penalty boxes. At the same time a bogus or hostile header can
    #   cost at most a quarter hour of reporting, not a shift: reporting
    #   resumes on its own well inside any on-call response window.
    MAX_DELAY = 900

    # @return [Integer] the longest Retry-After header worth inspecting.
    #   Anything longer is a hostile/garbage header, not a number of seconds
    #   or an HTTP-date (the longest legitimate HTTP-date is ~29 chars).
    MAX_RETRY_AFTER_LENGTH = 64

    # @return [Integer] minimum seconds between "sends are suppressed" log
    #   lines, so a notice storm against a rate-limiting endpoint can't also
    #   become a log storm
    LOG_INTERVAL = 10

    # @return [Integer] how many endpoints windows are tracked for. The real
    #   set is tiny (one error endpoint, a handful of APM destinations); the
    #   cap only exists so a backlog replaying odd endpoints can never grow
    #   the map without bound.
    MAX_TRACKED_ENDPOINTS = 64

    class << self
      include Loggable

      # Computes the backoff for a 429. Prefers the standard Retry-After
      # header (delta-seconds or HTTP-date), then the legacy Airbrake
      # X-RateLimit-Delay header, then DEFAULT_DELAY, so that a 429 always
      # results in a backoff.
      #
      # The result is NEVER unbounded and never negative: anything we cannot
      # trust becomes DEFAULT_DELAY and anything longer than MAX_DELAY is
      # clamped to it. See MAX_DELAY for why a header from the network is not
      # allowed to decide how long an app stops reporting.
      #
      # @param [Net::HTTPResponse] response
      # @return [Numeric] the delay in seconds (0 < delay <= MAX_DELAY)
      def delay_for(response)
        clamp(
          retry_after_delay(response['Retry-After']) ||
          legacy_delay(response['X-RateLimit-Delay']),
        )
      end

      private

      # @param [String, nil] header the raw Retry-After header
      # @return [Numeric, nil] the requested delay in seconds, or nil when the
      #   header is absent or not worth trusting
      def retry_after_delay(header)
        return unless header

        value = header.to_s.strip
        return if value.empty?

        if value.length > MAX_RETRY_AFTER_LENGTH
          logger.warn("#{LOG_LABEL} ignoring oversized Retry-After header")
          return
        end

        delay = /\A\d+\z/.match?(value) ? value.to_i : httpdate_delay(value)
        return delay if delay && delay > 0

        logger.warn("#{LOG_LABEL} ignoring untrustworthy Retry-After (#{value.inspect})")
        nil
      end

      # @param [String] value
      # @return [Numeric, nil] seconds until the given HTTP-date, or nil when
      #   it doesn't parse
      def httpdate_delay(value)
        Time.httpdate(value) - Time.now
      rescue ArgumentError
        nil
      end

      # @param [String, nil] header the legacy X-RateLimit-Delay header
      # @return [Integer, nil] the requested delay in seconds, or nil
      def legacy_delay(header)
        delay = header.to_i
        delay > 0 ? delay : nil
      end

      # @param [Numeric, nil] delay
      # @return [Numeric] a delay that is always positive and never longer
      #   than MAX_DELAY
      def clamp(delay)
        return DEFAULT_DELAY if delay.nil? || delay <= 0
        return delay if delay <= MAX_DELAY

        logger.warn(
          "#{LOG_LABEL} clamping requested rate-limit backoff of " \
          "#{delay.round}s to #{MAX_DELAY}s",
        )
        MAX_DELAY
      end
    end

    def initialize
      @mutex = Mutex.new
      @resets = {}
      @drops = 0
      @drops_logged = 0
      @last_log = nil
    end

    # Records the backoff window for +endpoint+. The window is computed (and
    # clamped) by {Response}, so a hostile or fat-fingered Retry-After cannot
    # blind the app for a shift.
    #
    # @param [URI::HTTPS, String] endpoint
    # @param [Time] reset when sends to +endpoint+ may resume
    # @return [void]
    def suppress(endpoint, reset)
      key = endpoint.to_s
      @mutex.synchronize do
        prune
        @resets[key] = reset
      end

      logger.warn(
        "#{LOG_LABEL} rate limited by #{key}: suppressing sends to it " \
        "until #{reset.getutc.iso8601}",
      )
    end

    # @param [URI::HTTPS, String] endpoint
    # @return [Time, nil] when sends to +endpoint+ resume, or nil when they
    #   are not suppressed
    def reset_at(endpoint)
      now = Time.now
      reset = @mutex.synchronize { @resets[endpoint.to_s] }

      reset if reset && reset > now
    end

    # @param [URI::HTTPS, String] endpoint
    # @return [Boolean] whether sends to +endpoint+ are currently suppressed
    def suppressed?(endpoint)
      !reset_at(endpoint).nil?
    end

    # @return [Integer] how many payloads have been dropped because their
    #   endpoint was rate limiting us (since this object was created)
    def drops
      @mutex.synchronize { @drops }
    end

    # Counts a dropped payload and logs at most one line per {LOG_INTERVAL}
    # seconds (with the drops accumulated since the last line and the time
    # reporting resumes). The critical section is a counter bump — the logger
    # call happens outside the lock so a slow host logger can never serialize
    # dropping threads.
    #
    # @param [URI::HTTPS, String] endpoint
    # @param [Time] reset
    # @return [void]
    def note_drop(endpoint, reset)
      dropped = nil
      total = nil

      @mutex.synchronize do
        @drops += 1
        now = MonotonicTime.time_in_s
        break if @last_log && now - @last_log < LOG_INTERVAL

        dropped = @drops - @drops_logged
        @drops_logged = @drops
        @last_log = now
        total = @drops
      end
      return unless dropped

      logger.warn(
        "#{LOG_LABEL} suppressing sends to #{endpoint} until " \
        "#{reset.getutc.iso8601}: dropped #{dropped} payload(s) " \
        "(#{total} total since startup)",
      )
    end

    private

    # Forgets expired windows once the map grows past MAX_TRACKED_ENDPOINTS.
    # Must be called while holding @mutex.
    #
    # @return [void]
    def prune
      return if @resets.size < MAX_TRACKED_ENDPOINTS

      now = Time.now
      @resets.delete_if { |_endpoint, reset| reset <= now }
    end
  end
end
