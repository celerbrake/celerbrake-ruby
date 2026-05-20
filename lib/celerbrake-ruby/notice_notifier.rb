module Celerbrake
  # NoticeNotifier is reponsible for sending notices to Celerbrake. It supports
  # synchronous and asynchronous delivery.
  #
  # @see Celerbrake::Config The list of options
  # @since v1.0.0
  # @api public
  class NoticeNotifier
    # @return [Array<Class>] filters to be executed first
    DEFAULT_FILTERS = [
      Celerbrake::Filters::SystemExitFilter,
      Celerbrake::Filters::GemRootFilter,

      # Optional filters (must be included by users):
      # Celerbrake::Filters::ThreadFilter
    ].freeze

    include Inspectable
    include Loggable

    def initialize
      @config = Celerbrake::Config.instance
      @filter_chain = FilterChain.new
      @async_sender = AsyncSender.new(:post, self.class.name)
      @sync_sender = SyncSender.new

      DEFAULT_FILTERS.each { |filter| add_filter(filter.new) }

      add_filter(Celerbrake::Filters::ContextFilter.new)
      add_filter(Celerbrake::Filters::ExceptionAttributesFilter.new)
    end

    # @see Celerbrake.notify
    def notify(exception, params = {}, &block)
      send_notice(exception, params, default_sender, &block)
    end

    # @see Celerbrake.notify_sync
    def notify_sync(exception, params = {}, &block)
      send_notice(exception, params, @sync_sender, &block).value
    end

    # @see Celerbrake.add_filte
    def add_filter(filter = nil, &block)
      @filter_chain.add_filter(block_given? ? block : filter)
    end

    # @see Celerbrake.delete_filter
    def delete_filter(filter_class)
      @filter_chain.delete_filter(filter_class)
    end

    # @see Celerbrake.build_notice
    def build_notice(exception, params = {})
      if @async_sender.closed?
        raise Celerbrake::Error,
              "Celerbrake is closed; can't build exception: " \
              "#{exception.class}: #{exception}"
      end

      if exception.is_a?(Celerbrake::Notice)
        exception[:params].merge!(params)
        exception
      else
        Notice.new(convert_to_exception(exception), params.dup)
      end
    end

    # @see Celerbrake.close
    def close
      @sync_sender.close
      @async_sender.close
    end

    # @see Celerbrake.configured?
    def configured?
      @config.valid?
    end

    # @see Celerbrake.merge_context
    def merge_context(context)
      Celerbrake::Context.current.merge!(context)
    end

    # @return [Boolean]
    # @since v4.14.0
    def has_filter?(filter_class) # rubocop:disable Naming/PredicateName
      @filter_chain.includes?(filter_class)
    end

    private

    def convert_to_exception(ex)
      if ex.is_a?(Exception) || Backtrace.java_exception?(ex)
        # Manually created exceptions don't have backtraces, so we create a fake
        # one, whose first frame points to the place where Celerbrake was called
        # (normally via `notify`).
        ex.set_backtrace(clean_backtrace) unless ex.backtrace
        return ex
      end

      e = RuntimeError.new(ex.to_s)
      e.set_backtrace(clean_backtrace)
      e
    end

    def send_notice(exception, params, sender)
      promise = @config.check_configuration
      return promise if promise.rejected?

      notice = build_notice(exception, params)
      yield notice if block_given?
      @filter_chain.refine(notice)

      promise = Celerbrake::Promise.new
      return promise.reject("#{notice} was marked as ignored") if notice.ignored?

      sender.send(notice, promise)
    end

    def default_sender
      return @async_sender if @async_sender.has_workers?

      logger.warn(
        "#{LOG_LABEL} falling back to sync delivery because there are no " \
        "running async workers",
      )
      @sync_sender
    end

    def clean_backtrace
      caller_copy = Kernel.caller
      clean_bt = caller_copy.drop_while { |frame| frame.include?('/lib/celerbrake') }

      # If true, then it's likely an internal library error. In this case return
      # at least some backtrace to simplify debugging.
      return caller_copy if clean_bt.empty?

      clean_bt
    end
  end
end
