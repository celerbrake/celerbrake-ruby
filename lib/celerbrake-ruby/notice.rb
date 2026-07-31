module Celerbrake
  # Represents a chunk of information that is meant to be either sent to
  # Celerbrake or ignored completely.
  #
  # @since v1.0.0
  class Notice
    # @return [Hash{Symbol=>String,Hash}] the information to be displayed in the
    #   Context tab in the dashboard
    CONTEXT = {
      os: RUBY_PLATFORM,
      language: "#{RUBY_ENGINE}/#{RUBY_VERSION}".freeze,
      notifier: Celerbrake::NOTIFIER_INFO,
    }.freeze

    # @return [Integer] the maxium size of the JSON payload in bytes
    MAX_NOTICE_SIZE = 64000

    # @return [Integer] the maximum size of hashes, arrays and strings in the
    #   notice.
    PAYLOAD_MAX_SIZE = 10000

    # @return [Array<StandardError>] the list of possible exceptions that might
    #   be raised when an object is converted to JSON
    JSON_EXCEPTIONS = [
      IOError,
      NotImplementedError,
      JSON::GeneratorError,
      Encoding::UndefinedConversionError,
    ].freeze

    # @return [Array<Symbol>] the list of keys that can be be overwritten with
    #   {Celerbrake::Notice#[]=}
    WRITABLE_KEYS = %i[notifier context environment session params].freeze

    # @return [Array<Symbol>] parts of a Notice's payload that can be modified
    #   by the truncator
    TRUNCATABLE_KEYS = %i[errors environment session params].freeze

    # @return [Symbol] the ONE truncatable part of the payload that this gem
    #   authors itself — `NestedException#as_json` + `Backtrace.parse`.
    #
    #   Everything else in {TRUNCATABLE_KEYS} is the host application's data,
    #   where a key named `type`/`file`/`function` means whatever the
    #   application meant by it. Only this subtree gets
    #   {Celerbrake::Truncator::IDENTITY_FLOOR}; widening it past `errors`
    #   re-introduces the defect that scoping exists to prevent.
    #
    #   THIS IS A CONVENTION, NOT AN ENFORCED BOUNDARY. `errors` is absent
    #   from {WRITABLE_KEYS}, but only {#[]=} consults that list; {#[]} hands
    #   back the LIVE payload object, and mutating it inside a
    #   `notify { |notice| … }` block is the documented public way to adjust a
    #   notice. The sibling `celerbrake` gem does exactly that — its
    #   `Celerbrake::Logger` rewrites `notice[:errors].first[:backtrace]` to
    #   drop internal Logger frames. So host code CAN reach into this subtree,
    #   and whatever it leaves behind under a `:type`/`:file`/`:function` key
    #   inherits {Celerbrake::Truncator::IDENTITY_FLOOR}.
    #
    #   That is acceptable, for three reasons. Reaching into `errors` is a
    #   deliberate act on the error's identity — the exact thing the floor
    #   protects — not the accidental collision that scoping exists to stop
    #   (a host symbol-keying its own `:type`/`:file` in `params`, which no
    #   longer reaches the floor at all). The floor is a floor and not an
    #   exemption, so the worst case is bounded: {IDENTITY_FLOOR} characters,
    #   up to ~1 KB of 4-byte UTF-8, per identity-named string. And the
    #   consequence of abusing it is the branch's already-documented failure
    #   mode — an inflated `errors` subtree converges one rung lower on the
    #   halving ladder — not a new one.
    #
    #   The line NOT to cross is doing this to a host-supplied subtree.
    #   {Celerbrake::Truncator#truncate_identity_subtree} must be called with
    #   this key and no other.
    IDENTITY_SUBTREE = :errors

    # @return [String] the name of the host machine
    HOSTNAME = Socket.gethostname.freeze

    # @return [String]
    DEFAULT_SEVERITY = 'error'.freeze

    include Ignorable
    include Loggable
    include Stashable

    # @api private
    def initialize(exception, params = {})
      @config = Celerbrake::Config.instance
      @truncator = Celerbrake::Truncator.new(PAYLOAD_MAX_SIZE)

      @payload = {
        errors: NestedException.new(exception).as_json,
        context: context(exception),
        environment: {
          program_name: $PROGRAM_NAME,
        },
        session: {},
        params: params,
      }

      stash[:exception] = exception
    end

    # Converts the notice to JSON. Calls +to_json+ on each object inside
    # notice's payload. Truncates notices, JSON representation of which is
    # bigger than {MAX_NOTICE_SIZE}.
    #
    # @return [Hash{String=>String}, nil]
    # @api private
    def to_json(*_args)
      loop do
        begin
          json = @payload.to_json
        rescue *JSON_EXCEPTIONS => ex
          logger.debug("#{LOG_LABEL} `notice.to_json` failed: #{ex.class}: #{ex}")
        else
          return json if json && json.bytesize <= MAX_NOTICE_SIZE
        end

        break if truncate == 0
      end
    end

    # Reads a value from notice's payload.
    #
    # @return [Object]
    # @raise [Celerbrake::Error] if the notice is ignored
    def [](key)
      raise_if_ignored
      @payload[key]
    end

    # Writes a value to the payload hash. Restricts unrecognized writes.
    #
    # @example
    #   notice[:params][:my_param] = 'foobar'
    #
    # @return [void]
    # @raise [Celerbrake::Error] if the notice is ignored
    # @raise [Celerbrake::Error] if the +key+ is not recognized
    # @raise [Celerbrake::Error] if the root value is not a Hash
    def []=(key, value)
      raise_if_ignored

      unless WRITABLE_KEYS.include?(key)
        raise Celerbrake::Error,
              ":#{key} is not recognized among #{WRITABLE_KEYS}"
      end

      unless value.respond_to?(:to_hash)
        raise Celerbrake::Error, "Got #{value.class} value, wanted a Hash"
      end

      @payload[key] = value.to_hash
    end

    private

    def context(exception)
      {
        version: @config.app_version,
        versions: @config.versions,
        # We ensure that root_directory is always a String, so it can always be
        # converted to JSON in a predictable manner (when it's a Pathname and in
        # Rails environment, it converts to unexpected JSON).
        rootDirectory: @config.root_directory.to_s,
        environment: @config.environment,

        # Make sure we always send hostname.
        hostname: HOSTNAME,

        severity: DEFAULT_SEVERITY,
        error_message: @truncator.truncate(exception.message),
      }.merge(CONTEXT).delete_if { |_key, val| val.nil? || val.empty? }
    end

    def truncate
      TRUNCATABLE_KEYS.each do |key|
        # ONE truncator, so the identity-aware pass and the ordinary pass can
        # never drift onto different rungs of the halving ladder; the scope is
        # carried by the method name instead of by a second instance.
        @payload[key] =
          if key == IDENTITY_SUBTREE
            @truncator.truncate_identity_subtree(@payload[key])
          else
            @truncator.truncate(@payload[key])
          end
      end

      new_max_size = @truncator.reduce_max_size
      if new_max_size == 0
        logger.error(
          "#{LOG_LABEL} truncation failed. File an issue at " \
          "https://github.com/celerbrake/celerbrake-ruby " \
          "and attach the following payload: #{@payload}",
        )
      end

      new_max_size
    end
  end
end
