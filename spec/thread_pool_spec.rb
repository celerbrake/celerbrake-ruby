RSpec.describe Celerbrake::ThreadPool do
  subject(:thread_pool) do
    described_class.new(
      worker_size: worker_size,
      queue_size: queue_size,
      block: proc { |message| tasks << message },
    )
  end

  let(:tasks) { [] }
  let(:worker_size) { 1 }
  let(:queue_size) { 2 }

  describe "#<<" do
    it "returns true" do
      retval = thread_pool << 1
      thread_pool.close
      expect(retval).to be(true)
    end

    it "performs work in background" do
      thread_pool << 2
      thread_pool << 1
      thread_pool.close

      expect(tasks).to eq([2, 1])
    end

    context "when the queue is full" do
      # No workers, so nothing drains the queue: after the first push the
      # SizedQueue is genuinely at capacity.
      subject(:full_thread_pool) do
        described_class.new(
          worker_size: 0,
          queue_size: 1,
          block: proc { |message| tasks << message },
        )
      end

      before { full_thread_pool << :filler }

      it "returns false" do
        retval = full_thread_pool << 1
        full_thread_pool.close
        expect(retval).to be(false)
      end

      it "discards tasks" do
        200.times { full_thread_pool << 1 }
        full_thread_pool.close

        expect(tasks.size).to be_zero
      end

      it "counts discarded tasks" do
        15.times { full_thread_pool << 1 }
        full_thread_pool.close

        expect(full_thread_pool.dropped_count).to eq(15)
      end

      it "logs discarded tasks at a throttled rate" do
        allow(Celerbrake::Loggable.instance).to receive(:info)

        15.times { full_thread_pool << 1 }
        full_thread_pool.close

        expect(Celerbrake::Loggable.instance)
          .to have_received(:info).once
      end
    end

    # DEFECT A regression: ThreadPool#<< used to be check-then-push — it read
    # the queue size and then called the *blocking* SizedQueue#push. Two host
    # request threads could both observe size == capacity - 1 and both push;
    # the loser slept inside Celerbrake.notify until the single worker popped
    # a message — and during an outage the worker sat inside an un-timed HTTP
    # call, hanging the host (Puma) thread for 60-120s.
    context "when the worker is stuck and the queue fills between the size check and the push" do
      it "returns false instead of blocking the calling thread" do
        started = Queue.new
        gate = Queue.new
        pool = described_class.new(
          worker_size: 1,
          queue_size: 1,
          # Parks the worker like an un-timed HTTP call during an outage.
          block: proc { |message| started << message; gate.pop },
        )

        pool << :parked
        started.pop # the worker is now inside the "HTTP call"
        expect(pool << :filler).to be(true) # the queue is now genuinely full

        # Encode the exact race deterministically: the old capacity check
        # reads a stale "there's room" size while the queue is actually full.
        # The fixed implementation never consults the size — it pushes
        # non-blockingly — so this stub is inert for it, but it forces the old
        # implementation down its blocking-push path.
        # rubocop:disable RSpec/SubjectStub
        allow(pool).to receive(:backlog).and_return(0)
        # rubocop:enable RSpec/SubjectStub

        pusher = Thread.new { pool << :racy_message }
        begin
          expect(pusher.join(2)).to eq(pusher) # nil join == the caller blocked
          expect(pusher.value).to be(false)
        ensure
          pusher.kill unless pusher.join(0)
          3.times { gate << :go }
          pool.close
        end
      end
    end

    context "when concurrent callers push at capacity" do
      it "never blocks any caller (timing-asserted)" do
        started = Queue.new
        gate = Queue.new
        pool = described_class.new(
          worker_size: 1,
          queue_size: 2,
          block: proc { |message| started << message; gate.pop },
        )

        pool << :parked
        started.pop # the worker is now parked inside the block
        2.times { expect(pool << :work).to be(true) } # fill to capacity

        results = Queue.new
        pushers = Array.new(4) do
          Thread.new do
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            retval = pool << :late_message
            results << [retval, Process.clock_gettime(Process::CLOCK_MONOTONIC) - start]
          end
        end

        begin
          pushers.each { |thread| expect(thread.join(2)).to eq(thread) }

          4.times do
            retval, elapsed = results.pop
            expect(retval).to be(false)
            expect(elapsed).to be < 0.5
          end
        ensure
          pushers.each { |thread| thread.kill unless thread.join(0) }
          5.times { gate << :go }
          pool.close
        end
      end
    end
  end

  describe "#backlog" do
    let(:worker_size) { 0 }

    it "returns the size of the queue" do
      thread_pool << 1
      expect(thread_pool.backlog).to eq(1)
    end
  end

  describe "#has_workers?" do
    it "returns false when the thread pool is not closed, but has 0 workers" do
      thread_pool.workers.list.each do |worker|
        worker.kill.join
      end
      expect(thread_pool).not_to have_workers
    end

    it "returns false when the thread pool is closed" do
      thread_pool.close
      expect(thread_pool).not_to have_workers
    end

    describe "forking behavior" do
      before do
        skip('fork() is unsupported on JRuby') if %w[jruby].include?(RUBY_ENGINE)
        unless Process.respond_to?(:last_status)
          skip('Process.last_status is unsupported on this Ruby')
        end
      end

      # rubocop:disable RSpec/MultipleExpectations
      it "respawns workers on fork()" do
        pid = fork { expect(thread_pool).to have_workers }
        Process.wait(pid)
        thread_pool.close

        expect(Process.last_status).to be_success
        expect(thread_pool).not_to have_workers
      end
      # rubocop:enable RSpec/MultipleExpectations

      it "ensures that a new thread group is created per process" do
        thread_pool << 1
        pid = fork { thread_pool.has_workers? }
        Process.wait(pid)
        thread_pool.close

        expect(Process.last_status).to be_success
      end
    end
  end

  describe "#close" do
    context "when there's no work to do" do
      it "joins the spawned thread" do
        workers = thread_pool.workers.list
        expect(workers).to all(be_alive)

        thread_pool.close
        expect(workers).to all(be_stop)
      end
    end

    context "when there's some work to do" do
      it "logs how many tasks are left to process" do
        allow(Celerbrake::Loggable.instance).to receive(:debug)

        thread_pool = described_class.new(
          name: 'foo', worker_size: 0, queue_size: 2, block: proc {},
        )

        2.times { thread_pool << 1 }
        thread_pool.close

        expect(Celerbrake::Loggable.instance).to have_received(:debug).with(
          /waiting to process \d+ task\(s\)/,
        )
        expect(Celerbrake::Loggable.instance).to have_received(:debug).with(/foo.+closed/)
      end

      it "waits until the queue gets empty" do
        thread_pool = described_class.new(
          worker_size: 1, queue_size: 2, block: proc {},
        )

        10.times { thread_pool << 1 }
        thread_pool.close
        expect(thread_pool.backlog).to be_zero
      end
    end

    # DEFECT A audit: #close used to push its :stop sentinels while holding
    # the same mutex #has_workers? takes. With a full queue and a stuck
    # worker, close blocked inside SizedQueue#push holding the lock — and
    # every host request thread calling Celerbrake.notify (whose sender picks
    # async/sync via #has_workers?) wedged behind the shutdown.
    context "when close is draining a full queue" do
      it "doesn't block has_workers? (the notify path)" do
        started = Queue.new
        gate = Queue.new
        pool = described_class.new(
          worker_size: 1,
          queue_size: 1,
          block: proc { |message| started << message; gate.pop },
        )

        pool << :parked
        started.pop # the worker is now parked inside the block
        expect(pool << :filler).to be(true) # the queue is now genuinely full

        closer = Thread.new { pool.close }
        sleep(0.1) # let close reach the (blocking) :stop sentinel push

        begin
          probe = Thread.new { pool.has_workers? }
          expect(probe.join(2)).to eq(probe) # nil join == the notify path hung
          expect(probe.value).to be(false)
        ensure
          2.times { gate << :go }
          closer.join
        end
      end
    end

    context "when it was already closed" do
      it "doesn't increase the queue size" do
        begin
          thread_pool.close
        rescue Celerbrake::Error
          nil
        end

        expect(thread_pool.backlog).to be_zero
      end

      it "raises error" do
        thread_pool.close
        expect { thread_pool.close }.to raise_error(
          Celerbrake::Error, 'this thread pool is closed already'
        )
      end
    end
  end

  describe "#spawn_workers" do
    after { thread_pool.close }

    let(:worker_size) { 3 }

    # We avoid enclosed thread groups since they cause issues for anyone using timeout 0.3.1
    # More info: https://github.com/celerbrake/celerbrake-ruby/issues/713
    it "spawns an unenclosed thread group" do
      expect(thread_pool.workers).to be_a(ThreadGroup)
      expect(thread_pool.workers).not_to be_enclosed
    end

    it "spawns threads that are alive" do
      expect(thread_pool.workers.list).to all(be_alive)
    end

    it "spawns exactly `workers_size` workers" do
      expect(thread_pool.workers.list.size).to eq(3)
    end
  end
end
