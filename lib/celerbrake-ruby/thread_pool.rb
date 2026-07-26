module Celerbrake
  # ThreadPool implements a simple thread pool that can configure the number of
  # worker threads and the size of the queue to process.
  #
  # @example
  #   # Initialize a new thread pool with 5 workers and a queue size of 100. Set
  #   # the block to be run concurrently.
  #   thread_pool = ThreadPool.new(
  #     name: 'performance-notifier',
  #     worker_size: 5,
  #     queue_size: 100,
  #     block: proc { |message| print "ECHO: #{message}..."}
  #   )
  #
  #   # Send work.
  #   10.times { |i| thread_pool << i }
  #   #=> ECHO: 0...ECHO: 1...ECHO: 2...
  #
  # @api private
  # @since v4.6.1
  class ThreadPool
    include Loggable

    # @return [Integer] minimum seconds between "queue is full" log lines, so a
    #   notice storm can't also become a log storm
    DROP_LOG_INTERVAL = 10

    # @return [ThreadGroup] the list of workers
    # @note This is exposed for eaiser unit testing
    attr_reader :workers

    # @return [Integer] how many messages have been dropped because the queue
    #   was full (kept since the pool was created)
    attr_reader :dropped_count

    def initialize(worker_size:, queue_size:, block:, name: nil)
      @name = name
      @worker_size = worker_size
      @queue_size = queue_size
      @block = block

      @queue = SizedQueue.new(queue_size)
      @workers = ThreadGroup.new
      @mutex = Mutex.new
      @pid = nil
      @closed = false

      @drop_mutex = Mutex.new
      @dropped_count = 0
      @drops_logged = 0
      @last_drop_log = nil

      has_workers?
    end

    # Adds a new message to the thread pool. Rejects messages if the queue is
    # at its capacity.
    #
    # This must NEVER block the calling thread: it runs inside the host app's
    # request path (Celerbrake.notify). The old implementation checked the
    # queue size and then did a *blocking* push — two threads could both pass
    # the check at capacity-1 and the loser would sleep inside SizedQueue#push
    # until a worker popped, which during an outage meant hanging a host
    # request thread for the duration of the HTTP timeout. Now we push
    # non-blockingly and count/drop on overflow instead.
    #
    # @param [Object] message The message that gets passed to the block
    # @return [Boolean] true if the message was successfully sent to the pool,
    #   false if the queue is full
    def <<(message)
      @queue.push(message, true)
      true
    rescue ThreadError, ClosedQueueError
      # ThreadError: the queue is full. ClosedQueueError: defensive — nothing
      # closes the underlying queue today, but pushing into a closed queue
      # must degrade to a dropped message, never an exception in the host app.
      note_dropped_message
      false
    end

    # @return [Integer] how big the queue is at the moment
    def backlog
      @queue.size
    end

    # Checks if a thread pool has any workers. A thread pool doesn't have any
    # workers only in two cases: when it was closed or when all workers
    # crashed. An *active* thread pool doesn't have any workers only when
    # something went wrong.
    #
    # Workers are expected to crash when you +fork+ the process the workers are
    # living in. In this case we detect a +fork+ and try to revive them here.
    #
    # Another possible scenario that crashes workers is when you close the
    # instance on +at_exit+, but some other +at_exit+ hook prevents the process
    # from exiting.
    #
    # @return [Boolean] true if an instance wasn't closed, but has no workers
    # @see https://goo.gl/oydz8h Example of at_exit that prevents exit
    def has_workers?
      @mutex.synchronize do
        return false if @closed

        if @pid != Process.pid && @workers.list.empty?
          @pid = Process.pid
          @workers = ThreadGroup.new
          spawn_workers
        end

        !@closed && @workers.list.any?
      end
    end

    # Closes the thread pool making it a no-op (it shut downs all worker
    # threads). Before closing, waits on all unprocessed tasks to be processed.
    #
    # @return [void]
    # @raise [Celerbrake::Error] when invoked more than one time
    def close
      threads = @mutex.synchronize do
        raise Celerbrake::Error, 'this thread pool is closed already' if @closed

        unless @queue.empty?
          msg = "#{LOG_LABEL} waiting to process #{@queue.size} task(s)..."
          logger.debug("#{msg} (Ctrl-C to abort)")
        end

        @closed = true
        @workers.list.dup
      end

      # Push the :stop sentinels OUTSIDE the mutex: pushing into a full queue
      # blocks until workers drain it, and holding @mutex during that wait
      # would wedge every caller of #has_workers? (i.e. the notify path of
      # every host request thread) behind the shutdown.
      @worker_size.times { @queue << :stop }

      threads.each(&:join)
      logger.debug("#{LOG_LABEL} #{@name} thread pool closed")
    end

    def closed?
      @closed
    end

    def spawn_workers
      @worker_size.times { @workers.add(spawn_worker) }
    end

    private

    # Counts a dropped message and logs at most once per DROP_LOG_INTERVAL
    # seconds (with the number of drops accumulated since the last line).
    # Cheap and non-blocking: the critical section is a counter bump — the
    # logger call happens outside the lock so a slow host logger can never
    # serialize dropping threads.
    #
    # @return [void]
    def note_dropped_message
      dropped = nil
      total = nil

      @drop_mutex.synchronize do
        @dropped_count += 1
        now = MonotonicTime.time_in_s
        break if @last_drop_log && now - @last_drop_log < DROP_LOG_INTERVAL

        dropped = @dropped_count - @drops_logged
        @drops_logged = @dropped_count
        @last_drop_log = now
        total = @dropped_count
      end
      return unless dropped

      logger.info do
        "#{LOG_LABEL} ThreadPool has reached its capacity of " \
        "#{@queue_size}: dropped #{dropped} message(s) " \
        "(#{total} total since startup)"
      end
    end

    def spawn_worker
      Thread.new do
        while (message = @queue.pop)
          break if message == :stop

          @block.call(message)
        end
      end
    end
  end
end
