require 'net/https'
require 'logger'
require 'json'
require 'set'
require 'socket'
require 'time'

require 'celerbrake-ruby/version'
require 'celerbrake-ruby/loggable'
require 'celerbrake-ruby/stashable'
require 'celerbrake-ruby/mergeable'
require 'celerbrake-ruby/grouppable'
require 'celerbrake-ruby/config'
require 'celerbrake-ruby/config/validator'
require 'celerbrake-ruby/config/processor'
require 'celerbrake-ruby/remote_settings/callback'
require 'celerbrake-ruby/remote_settings/settings_data'
require 'celerbrake-ruby/remote_settings'
require 'celerbrake-ruby/promise'
require 'celerbrake-ruby/thread_pool'
require 'celerbrake-ruby/response'
require 'celerbrake-ruby/sync_sender'
require 'celerbrake-ruby/async_sender'
require 'celerbrake-ruby/nested_exception'
require 'celerbrake-ruby/ignorable'
require 'celerbrake-ruby/inspectable'
require 'celerbrake-ruby/notice'
require 'celerbrake-ruby/backtrace'
require 'celerbrake-ruby/truncator'
require 'celerbrake-ruby/filters/keys_filter'
require 'celerbrake-ruby/filters/keys_allowlist'
require 'celerbrake-ruby/filters/keys_blocklist'
require 'celerbrake-ruby/filters/gem_root_filter'
require 'celerbrake-ruby/filters/system_exit_filter'
require 'celerbrake-ruby/filters/root_directory_filter'
require 'celerbrake-ruby/filters/thread_filter'
require 'celerbrake-ruby/filters/context_filter'
require 'celerbrake-ruby/filters/exception_attributes_filter'
require 'celerbrake-ruby/filters/dependency_filter'
require 'celerbrake-ruby/filters/git_revision_filter'
require 'celerbrake-ruby/filters/git_repository_filter'
require 'celerbrake-ruby/filters/git_last_checkout_filter'
require 'celerbrake-ruby/filters/sql_filter'
require 'celerbrake-ruby/filter_chain'
require 'celerbrake-ruby/code_hunk'
require 'celerbrake-ruby/file_cache'
require 'celerbrake-ruby/hash_keyable'
require 'celerbrake-ruby/performance_notifier'
require 'celerbrake-ruby/notice_notifier'
require 'celerbrake-ruby/deploy_notifier'
require 'celerbrake-ruby/stat'
require 'celerbrake-ruby/time_truncate'
require 'celerbrake-ruby/tdigest'
require 'celerbrake-ruby/query'
require 'celerbrake-ruby/request'
require 'celerbrake-ruby/performance_breakdown'
require 'celerbrake-ruby/benchmark'
require 'celerbrake-ruby/monotonic_time'
require 'celerbrake-ruby/timed_trace'
require 'celerbrake-ruby/queue'
require 'celerbrake-ruby/context'
require 'celerbrake-ruby/backlog'

# Celerbrake is a thin wrapper around instances of the notifier classes (such as
# notice, performance & deploy notifiers). It creates a way to access them via a
# consolidated global interface.
#
# Prior to using it, you must {configure} it.
#
# @example
#   Celerbrake.configure do |c|
#     c.project_id = 113743
#     c.project_key = 'fd04e13d806a90f96614ad8e529b2822'
#   end
#
#   Celerbrake.notify('Oops!')
#
# @since v1.0.0
# @api public
# rubocop:disable Metrics/ModuleLength
module Celerbrake
  # The general error that this library uses when it wants to raise.
  Error = Class.new(StandardError)

  # @return [String] the label to be prepended to the log output
  LOG_LABEL = '**Celerbrake:'.freeze

  # @return [Boolean] true if current Ruby is JRuby. The result is used for
  #  special cases where we need to work around older implementations
  JRUBY = (RUBY_ENGINE == 'jruby')

  # @return [Boolean] true if this Ruby supports safe levels and tainting,
  #  to guard against using deprecated or unsupported features.
  HAS_SAFE_LEVEL = (
    RUBY_ENGINE == 'ruby' &&
    Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.7')
  )

  class << self
    # @since v4.2.3
    # @api private
    attr_writer :performance_notifier

    # @since v4.2.3
    # @api private
    attr_writer :notice_notifier

    # @since v4.2.3
    # @api private
    attr_writer :deploy_notifier

    # Configures the Celerbrake notifier.
    #
    # @example
    #   Celerbrake.configure do |c|
    #     c.project_id = 113743
    #     c.project_key = 'fd04e13d806a90f96614ad8e529b2822'
    #   end
    #
    # @yield [config]
    # @yieldparam config [Celerbrake::Config]
    # @return [void]
    def configure
      yield config = Celerbrake::Config.instance
      Celerbrake::Loggable.instance = config.logger

      config_processor = Celerbrake::Config::Processor.new(config)

      config_processor.process_blocklist(notice_notifier)
      config_processor.process_allowlist(notice_notifier)

      @remote_settings ||= config_processor.process_remote_configuration

      config_processor.add_filters(notice_notifier)
    end

    # @since v4.2.3
    # @api private
    def performance_notifier
      @performance_notifier ||= PerformanceNotifier.new
    end

    # @since v4.2.3
    # @api private
    def notice_notifier
      @notice_notifier ||= NoticeNotifier.new
    end

    # @since v4.2.3
    # @api private
    def deploy_notifier
      @deploy_notifier ||= DeployNotifier.new
    end

    # @return [Boolean] true if the notifier was configured, false otherwise
    # @since v2.3.0
    def configured?
      @notice_notifier && @notice_notifier.configured?
    end

    # Sends an exception to Celerbrake asynchronously.
    #
    # @example Sending an exception
    #   Celerbrake.notify(RuntimeError.new('Oops!'))
    # @example Sending a string
    #   # Converted to RuntimeError.new('Oops!') internally
    #   Celerbrake.notify('Oops!')
    # @example Sending a Notice
    #   notice = celerbrake.build_notice(RuntimeError.new('Oops!'))
    #   celerbrake.notify(notice)
    #
    # @param [Exception, String, Celerbrake::Notice] exception The exception to be
    #   sent to Celerbrake
    # @param [Hash] params The additional payload to be sent to Celerbrake. Can
    #   contain any values. The provided values will be displayed in the Params
    #   tab in your project's dashboard
    # @yield [notice] The notice to filter
    # @yieldparam [Celerbrake::Notice]
    # @yieldreturn [void]
    # @return [Celerbrake::Promise]
    # @see .notify_sync
    def notify(exception, params = {}, &block)
      notice_notifier.notify(exception, params, &block)
    end

    # Sends an exception to Celerbrake synchronously.
    #
    # @example
    #   Celerbrake.notify_sync('App crashed!')
    #   #=> {"id"=>"123", "url"=>"https://celerbrake.com/locate/321"}
    #
    # @param [Exception, String, Celerbrake::Notice] exception The exception to be
    #   sent to Celerbrake
    # @param [Hash] params The additional payload to be sent to Celerbrake. Can
    #   contain any values. The provided values will be displayed in the Params
    #   tab in your project's dashboard
    # @yield [notice] The notice to filter
    # @yieldparam [Celerbrake::Notice]
    # @yieldreturn [void]
    # @return [Celerbrake::Promise] the reponse from the server
    # @see .notify
    def notify_sync(exception, params = {}, &block)
      notice_notifier.notify_sync(exception, params, &block)
    end

    # Runs a callback before {.notify} or {.notify_sync} kicks in. This is
    # useful if you want to ignore specific notices or filter the data the
    # notice contains.
    #
    # @example Ignore all notices
    #   Celerbrake.add_filter(&:ignore!)
    # @example Ignore based on some condition
    #   Celerbrake.add_filter do |notice|
    #     notice.ignore! if notice[:error_class] == 'StandardError'
    #   end
    # @example Ignore with help of a class
    #   class MyFilter
    #     def call(notice)
    #       # ...
    #     end
    #   end
    #
    #   Celerbrake.add_filter(MyFilter.new)
    #
    # @param [#call] filter The filter object
    # @yield [notice] The notice to filter
    # @yieldparam [Celerbrake::Notice]
    # @yieldreturn [void]
    # @return [void]
    def add_filter(filter = nil, &block)
      notice_notifier.add_filter(filter, &block)
    end

    # Deletes a filter added via {Celerbrake#add_filter}.
    #
    # @example
    #   # Add a MyFilter filter (we pass an instance here).
    #   Celerbrake.add_filter(MyFilter.new)
    #
    #   # Delete the filter (we pass class name here).
    #   Celerbrake.delete_filter(MyFilter)
    #
    # @param [Class] filter_class The class of the filter you want to delete
    # @return [void]
    # @since v3.1.0
    # @note This method cannot delete filters assigned via the Proc form.
    def delete_filter(filter_class)
      notice_notifier.delete_filter(filter_class)
    end

    # Builds an Celerbrake notice. This is useful, if you want to add or modify a
    # value only for a specific notice. When you're done modifying the notice,
    # send it with {.notify} or {.notify_sync}.
    #
    # @example
    #   notice = celerbrake.build_notice('App crashed!')
    #   notice[:params][:username] = user.name
    #   celerbrake.notify_sync(notice)
    #
    # @param [Exception] exception The exception on top of which the notice
    #   should be built
    # @param [Hash] params The additional params attached to the notice
    # @return [Celerbrake::Notice] the notice built with help of the given
    #   arguments
    def build_notice(exception, params = {})
      notice_notifier.build_notice(exception, params)
    end

    # Makes the notice notifier a no-op, which means you cannot use the
    # {.notify} and {.notify_sync} methods anymore. It also stops the notice
    # notifier's worker threads.
    #
    # @example
    #   Celerbrake.close
    #   Celerbrake.notify('App crashed!') #=> raises Celerbrake::Error
    #
    # @return [nil]
    # rubocop:disable Style/IfUnlessModifier
    def close
      if defined?(@notice_notifier) && @notice_notifier
        @notice_notifier.close
      end

      if defined?(@performance_notifier) && @performance_notifier
        @performance_notifier.close
      end

      if defined?(@remote_settings) && @remote_settings
        @remote_settings.stop_polling
      end

      nil
    end
    # rubocop:enable Style/IfUnlessModifier

    # Pings the Celerbrake Deploy API endpoint about the occurred deploy.
    #
    # @param [Hash{Symbol=>String}] deploy_info The params for the API
    # @option deploy_info [Symbol] :environment
    # @option deploy_info [Symbol] :username
    # @option deploy_info [Symbol] :repository
    # @option deploy_info [Symbol] :revision
    # @option deploy_info [Symbol] :version
    # @return [void]
    def notify_deploy(deploy_info)
      deploy_notifier.notify(deploy_info)
    end

    # Merges +context+ with the current context.
    #
    # The context will be attached to the notice object upon a notify call and
    # cleared after it's attached. The context data is attached to the
    # `params/celerbrake_context` key.
    #
    # @example
    #   class MerryGrocer
    #     def load_fruits(fruits)
    #       Celerbrake.merge_context(fruits: fruits)
    #     end
    #
    #     def deliver_fruits
    #       Celerbrake.notify('fruitception')
    #     end
    #
    #     def load_veggies(veggies)
    #       Celerbrake.merge_context(veggies: veggies)
    #     end
    #
    #     def deliver_veggies
    #       Celerbrake.notify('veggieboom!')
    #     end
    #   end
    #
    #   grocer = MerryGrocer.new
    #
    #   # Load some fruits to the context.
    #   grocer.load_fruits(%w(mango banana apple))
    #
    #   # Deliver the fruits. Note that we are not passing anything,
    #   # `deliver_fruits` knows that we loaded something.
    #   grocer.deliver_fruits
    #
    #   # Load some vegetables and deliver them to Celerbrake. Note that the
    #   # fruits have been delivered and therefore the grocer doesn't have them
    #   # anymore. We merge veggies with the new context.
    #   grocer.load_veggies(%w(cabbage carrot onion))
    #   grocer.deliver_veggies
    #
    #   # The context is empty again, feel free to load more.
    #
    # @param [Hash{Symbol=>Object}] context
    # @return [void]
    def merge_context(context)
      notice_notifier.merge_context(context)
    end

    # Increments request statistics of a certain +route+ invoked with +method+,
    # which returned +status_code+.
    #
    # After a certain amount of time (n seconds) the aggregated route
    # information will be sent to Celerbrake.
    #
    # @example
    #   Celerbrake.notify_request(
    #     method: 'POST',
    #     route: '/thing/:id/create',
    #     status_code: 200,
    #     timing: 123.45 # ms
    #   )
    #
    # @param [Hash{Symbol=>Object}] request_info
    # @option request_info [String] :method The HTTP method that was invoked
    # @option request_info [String] :route The route that was invoked
    # @option request_info [Integer] :status_code The response code that the
    #   route returned
    # @option request_info [Float] :timing  How much time it took to process the
    #   request (in ms)
    # @param [Hash] stash What needs to be appeneded to the stash, so it's
    #   available in filters
    # @return [void]
    # @since v3.0.0
    # @see Celerbrake::PerformanceNotifier#notify
    def notify_request(request_info, stash = {})
      request = Request.new(**request_info)
      request.stash.merge!(stash)
      performance_notifier.notify(request)
    end

    # Synchronously increments request statistics of a certain +route+ invoked
    # with +method+, which returned +status_code+.
    # @since v4.10.0
    # @see .notify_request
    def notify_request_sync(request_info, stash = {})
      request = Request.new(**request_info)
      request.stash.merge!(stash)
      performance_notifier.notify_sync(request)
    end

    # Increments SQL statistics of a certain +query+. When +method+ and +route+
    # are provided, the query is grouped by these parameters.
    #
    # After a certain amount of time (n seconds) the aggregated query
    # information will be sent to Celerbrake.
    #
    # @example
    #   Celerbrake.notify_query(
    #     method: 'GET',
    #     route: '/things',
    #     query: 'SELECT * FROM things',
    #     func: 'do_stuff',
    #     file: 'app/models/foo.rb',
    #     line: 452,
    #     timing: 123.45 # ms
    #   )
    #
    # @param [Hash{Symbol=>Object}] query_info
    # @option query_info [String] :method The HTTP method that triggered this
    #   SQL query (optional)
    # @option query_info [String] :route The route that triggered this SQL
    #    query (optional)
    # @option query_info [String] :query The query that was executed
    # @option request_info [String] :func The function that called the query
    #   (optional)
    # @option request_info [String] :file The file that has the function that
    #   called the query (optional)
    # @option request_info [Integer] :line The line that executes the query
    #   (optional)
    # @option query_info [Float] :timing How much time it took to process the
    #   query (in ms)
    # @param [Hash] stash What needs to be appeneded to the stash, so it's
    #   available in filters
    # @return [void]
    # @since v3.2.0
    # @see Celerbrake::PerformanceNotifier#notify
    def notify_query(query_info, stash = {})
      query = Query.new(**query_info)
      query.stash.merge!(stash)
      performance_notifier.notify(query)
    end

    # Synchronously increments SQL statistics of a certain +query+. When
    # +method+ and +route+ are provided, the query is grouped by these
    # parameters.
    # @since v4.10.0
    # @see .notify_query
    def notify_query_sync(query_info, stash = {})
      query = Query.new(**query_info)
      query.stash.merge!(stash)
      performance_notifier.notify_sync(query)
    end

    # Increments performance breakdown statistics of a certain route.
    #
    # @example
    #   Celerbrake.notify_performance_breakdown(
    #     method: 'POST',
    #     route: '/thing/:id/create',
    #     response_type: 'json',
    #     groups: { db: 24.0, view: 0.4 }, # ms
    #     timing: 123.45 # ms
    #   )
    #
    # @param [Hash{Symbol=>Object}] breakdown_info
    # @option breakdown_info [String] :method HTTP method
    # @option breakdown_info [String] :route
    # @option breakdown_info [String] :response_type
    # @option breakdown_info [Array<Hash{Symbol=>Float}>] :groups
    # @option breakdown_info [Float] :timing How much time it took to process
    #   the performance breakdown (in ms)
    # @param [Hash] stash What needs to be appeneded to the stash, so it's
    #   available in filters
    # @return [void]
    # @since v4.2.0
    def notify_performance_breakdown(breakdown_info, stash = {})
      performance_breakdown = PerformanceBreakdown.new(**breakdown_info)
      performance_breakdown.stash.merge!(stash)
      performance_notifier.notify(performance_breakdown)
    end

    # Increments performance breakdown statistics of a certain route
    # synchronously.
    # @since v4.10.0
    # @see .notify_performance_breakdown
    def notify_performance_breakdown_sync(breakdown_info, stash = {})
      performance_breakdown = PerformanceBreakdown.new(**breakdown_info)
      performance_breakdown.stash.merge!(stash)
      performance_notifier.notify_sync(performance_breakdown)
    end

    # Increments statistics of a certain queue (worker).
    #
    # @example
    #   Celerbrake.notify_queue(
    #     queue: 'emails',
    #     error_count: 1,
    #     groups: { redis: 24.0, sql: 0.4 } # ms
    #   )
    #
    # @param [Hash{Symbol=>Object}] queue_info
    # @option queue_info [String] :queue The name of the queue/worker
    # @option queue_info [Integer] :error_count How many times this worker
    #   failed
    # @option queue_info [Array<Hash{Symbol=>Float}>] :groups Where the job
    #   spent its time
    # @option breakdown_info [Float] :timing How much time it took to process
    #   the queue (in ms)
    # @param [Hash] stash What needs to be appended to the stash, so it's
    #   available in filters
    # @return [void]
    # @since v4.9.0
    # @see .notify_queue_sync
    def notify_queue(queue_info, stash = {})
      queue = Queue.new(**queue_info)
      queue.stash.merge!(stash)
      performance_notifier.notify(queue)
    end

    # Increments statistics of a certain queue (worker) synchronously.
    # @since v4.10.0
    # @see .notify_queue
    def notify_queue_sync(queue_info, stash = {})
      queue = Queue.new(**queue_info)
      queue.stash.merge!(stash)
      performance_notifier.notify_sync(queue)
    end

    # Runs a callback before {.notify_request}, {.notify_query}, {.notify_queue}
    # or {.notify_performance_breakdown} kicks in. This is useful if you want to
    # ignore specific metrics or filter the data the metric contains.
    #
    # @example Ignore all metrics
    #   Celerbrake.add_performance_filter(&:ignore!)
    # @example Filter sensitive data
    #   Celerbrake.add_performance_filter do |metric|
    #     case metric
    #     when Celerbrake::Query
    #       metric.route = '[Filtered]'
    #     when Celerbrake::Request
    #       metric.query = '[Filtered]'
    #     end
    #   end
    # @example Filter with help of a class
    #   class MyFilter
    #     def call(metric)
    #       # ...
    #     end
    #   end
    #
    #   Celerbrake.add_performance_filter(MyFilter.new)
    #
    # @param [#call] filter The filter object
    # @yield [metric] The metric to filter
    # @yieldparam [Celerbrake::Query, Celerbrake::Request]
    # @yieldreturn [void]
    # @return [void]
    # @since v3.2.0
    # @see Celerbrake::PerformanceNotifier#add_filter
    def add_performance_filter(filter = nil, &block)
      performance_notifier.add_filter(filter, &block)
    end

    # Deletes a filter added via {Celerbrake#add_performance_filter}.
    #
    # @example
    #   # Add a MyFilter filter (we pass an instance here).
    #   Celerbrake.add_performance_filter(MyFilter.new)
    #
    #   # Delete the filter (we pass class name here).
    #   Celerbrake.delete_performance_filter(MyFilter)
    #
    # @param [Class] filter_class The class of the filter you want to delete
    # @return [void]
    # @since v3.2.0
    # @note This method cannot delete filters assigned via the Proc form.
    # @see Celerbrake::PerformanceNotifier#delete_filter
    def delete_performance_filter(filter_class)
      performance_notifier.delete_filter(filter_class)
    end

    # Resets all notifiers, including its filters
    # @return [void]
    # @since v4.2.2
    def reset
      close

      self.performance_notifier = PerformanceNotifier.new
      self.notice_notifier = NoticeNotifier.new
      self.deploy_notifier = DeployNotifier.new
    end
  end
end
# rubocop:enable Metrics/ModuleLength
