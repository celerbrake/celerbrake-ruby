RSpec.describe Celerbrake::SyncSender do
  subject(:sync_sender) { described_class.new }

  let(:mock_backlog) { instance_double(Celerbrake::Backlog) }

  before do
    Celerbrake::Config.instance = Celerbrake::Config.new(
      project_id: 1, project_key: 'banana',
    )
    allow(Celerbrake::Backlog).to receive(:new).and_return(mock_backlog)
  end

  describe "#send" do
    let(:promise) { Celerbrake::Promise.new }

    let(:notice) { Celerbrake::Notice.new(CelerbrakeTestError.new) }
    let(:endpoint) { 'https://api.celerbrake.com/api/v3/projects/1/notices' }

    before { stub_request(:post, endpoint).to_return(body: '{}') }

    it "sets the Content-Type header to JSON" do
      sync_sender.send({}, promise)
      expect(
        a_request(:post, endpoint).with(
          headers: { 'Content-Type' => 'application/json' },
        ),
      ).to have_been_made.once
    end

    it "sets the User-Agent header to the notifier slug" do
      sync_sender.send({}, promise)
      expect(
        a_request(:post, endpoint).with(
          headers: {
            'User-Agent' => %r{
              celerbrake-ruby/\d+\.\d+\.\d+(\.rc\.\d+)?\sRuby/\d+\.\d+\.\d+
            }x,
          },
        ),
      ).to have_been_made.once
    end

    it "sets the Authorization header to the project key" do
      sync_sender.send({}, promise)
      expect(
        a_request(:post, endpoint).with(
          headers: { 'Authorization' => 'Bearer banana' },
        ),
      ).to have_been_made.once
    end

    it "catches exceptions raised while sending" do
      # rubocop:disable RSpec/VerifiedDoubles
      https = double("foo")
      # rubocop:enable RSpec/VerifiedDoubles

      # rubocop:disable RSpec/SubjectStub
      allow(sync_sender).to receive(:build_https).and_return(https)
      # rubocop:enable RSpec/SubjectStub

      allow(https).to receive(:request).and_raise(StandardError.new('foo'))

      expect(sync_sender.send({}, promise)).to be_an(Celerbrake::Promise)
      expect(promise.value).to eq('error' => '**Celerbrake: HTTP error: foo')
    end

    it "logs exceptions raised while sending" do
      allow(Celerbrake::Loggable.instance).to receive(:error)

      # rubocop:disable RSpec/VerifiedDoubles
      https = double("foo")
      # rubocop:enable RSpec/VerifiedDoubles

      # rubocop:disable RSpec/SubjectStub
      allow(sync_sender).to receive(:build_https).and_return(https)
      # rubocop:enable RSpec/SubjectStub

      allow(https).to receive(:request).and_raise(StandardError.new('foo'))

      sync_sender.send({}, promise)

      expect(Celerbrake::Loggable.instance).to have_received(:error).with(
        /HTTP error: foo/,
      )
    end

    context "when request body is nil" do
      # rubocop:disable RSpec/MultipleExpectations
      it "doesn't send data" do
        allow(Celerbrake::Loggable.instance).to receive(:error)

        allow_any_instance_of(Celerbrake::Truncator)
          .to receive(:reduce_max_size).and_return(0)

        encoded = Base64.encode64("\xD3\xE6\xBC\x9D\xBA").encode!('ASCII-8BIT')
        bad_string = Base64.decode64(encoded)

        ex = CelerbrakeTestError.new
        backtrace = []
        10.times { backtrace << "bin/rails:3:in `<#{bad_string}>'" }
        ex.set_backtrace(backtrace)

        notice = Celerbrake::Notice.new(ex)

        expect(sync_sender.send(notice, promise)).to be_an(Celerbrake::Promise)
        expect(promise.value)
          .to match('error' => '**Celerbrake: data was not sent because of missing body')

        expect(Celerbrake::Loggable.instance).to have_received(:error).with(
          /data was not sent/,
        )
        expect(Celerbrake::Loggable.instance).to have_received(:error).with(
          /truncation failed/,
        )
      end
      # rubocop:enable RSpec/MultipleExpectations
    end

    context "when IP is rate limited" do
      let(:endpoint) { %r{https://api.celerbrake.com/api/v3/projects/1/notices} }

      before do
        stub_request(:post, endpoint).to_return(
          status: 429,
          body: '{"message":"IP is rate limited"}',
          headers: { 'X-RateLimit-Delay' => '1' },
        )
        allow(mock_backlog).to receive(:<<)
      end

      # rubocop:disable RSpec/MultipleExpectations
      it "returns error" do
        p1 = Celerbrake::Promise.new
        sync_sender.send({}, p1)
        expect(p1.value).to match('error' => '**Celerbrake: IP is rate limited')

        p2 = Celerbrake::Promise.new
        sync_sender.send({}, p2)
        expect(p2.value).to match('error' => '**Celerbrake: IP is rate limited')

        # Wait for X-RateLimit-Delay and then make a new request to make sure p2
        # was ignored (no request made for it).
        sleep 1

        p3 = Celerbrake::Promise.new
        sync_sender.send({}, p3)
        expect(p3.value).to match('error' => '**Celerbrake: IP is rate limited')

        expect(a_request(:post, endpoint)).to have_been_made.twice
      end
      # rubocop:enable RSpec/MultipleExpectations
    end

    # DEFECT B regression (backoff half): the Celerbrake server rate limits
    # per project with 429 + Retry-After. The client must back off instead of
    # hot-retrying — one HTTP attempt per notice against a rate-limiting
    # server would keep the pressure on and keep the worker busy for nothing.
    context "when the server responds with 429 and a Retry-After header" do
      let(:endpoint) { %r{https://api.celerbrake.com/api/v3/projects/1/notices} }

      before do
        stub_request(:post, endpoint).to_return(
          status: 429,
          # Deliberately NOT JSON: rack-level throttles send plain text, and a
          # malformed body must not defeat the backoff.
          body: 'Too Many Requests',
          headers: { 'Retry-After' => '30' },
        )
        allow(mock_backlog).to receive(:<<)
      end

      # rubocop:disable RSpec/MultipleExpectations
      it "backs off instead of hot-retrying" do
        p1 = Celerbrake::Promise.new
        sync_sender.send({}, p1)
        expect(p1).to be_rejected

        p2 = Celerbrake::Promise.new
        sync_sender.send({}, p2)
        expect(p2.value).to match('error' => /IP is rate limited/)

        expect(a_request(:post, endpoint)).to have_been_made.once
      end
      # rubocop:enable RSpec/MultipleExpectations
    end

    # BLOCKER regression (observable suppression): while a 429 backoff is in
    # effect the sender drops every payload. Silent drops are undetectable —
    # an operator (or an agent triaging "why did this app go quiet?") must be
    # able to see that reporting is suppressed and until when.
    context "when a 429 suppresses the sender" do
      let(:endpoint) { %r{https://api.celerbrake.com/api/v3/projects/1/notices} }

      before do
        stub_request(:post, endpoint).to_return(
          status: 429,
          body: 'Too Many Requests',
          # A hostile/misconfigured intermediary asking for a full day off.
          headers: { 'Retry-After' => '86400' },
        )
        allow(mock_backlog).to receive(:<<)
      end

      # rubocop:disable RSpec/MultipleExpectations
      it "exposes the (clamped) suppression window" do
        sync_sender.send({}, Celerbrake::Promise.new)

        expect(sync_sender).to be_rate_limited
        expect(sync_sender.rate_limit_reset).to be_within(5).of(
          Time.now + Celerbrake::Response::MAX_RATE_LIMIT_DELAY,
        )
      end
      # rubocop:enable RSpec/MultipleExpectations

      it "counts the payloads it drops while suppressed" do
        3.times { sync_sender.send({}, Celerbrake::Promise.new) }

        # The first send made the HTTP request that triggered the 429; the
        # other two were dropped without touching the network.
        expect(sync_sender.rate_limited_drops).to eq(2)
      end

      it "logs the suppression window once it starts dropping" do
        allow(Celerbrake::Loggable.instance).to receive(:warn)

        2.times { sync_sender.send({}, Celerbrake::Promise.new) }

        expect(Celerbrake::Loggable.instance).to have_received(:warn).with(
          /suppressing sends .+ until/,
        ).at_least(:once)
      end

      it "throttles the suppression log under a storm of drops" do
        allow(Celerbrake::Loggable.instance).to receive(:warn)

        50.times { sync_sender.send({}, Celerbrake::Promise.new) }

        # 49 drops, one line: a notice storm must not become a log storm.
        expect(Celerbrake::Loggable.instance)
          .to have_received(:warn).with(/dropped \d+ payload/).once
      end
    end

    # The suppression bookkeeping added a lock to the send path, which is
    # reached from every worker thread (and from notify_sync on a host request
    # thread). It must stay a counter bump: no deadlock, no serialization,
    # and every drop accounted for.
    context "when many threads send while suppressed" do
      let(:endpoint) { %r{https://api.celerbrake.com/api/v3/projects/1/notices} }

      before do
        stub_request(:post, endpoint).to_return(
          status: 429, body: 'Too Many Requests', headers: { 'Retry-After' => '600' },
        )
        allow(mock_backlog).to receive(:<<)
      end

      # rubocop:disable RSpec/MultipleExpectations
      it "never blocks a caller and counts every drop" do
        sync_sender.send({}, Celerbrake::Promise.new) # arm the suppression

        senders = Array.new(8) do
          Thread.new { 50.times { sync_sender.send({}, Celerbrake::Promise.new) } }
        end

        begin
          senders.each { |thread| expect(thread.join(5)).to eq(thread) }
          expect(sync_sender.rate_limited_drops).to eq(8 * 50)
        ensure
          senders.each { |thread| thread.kill unless thread.join(0) }
        end
      end
      # rubocop:enable RSpec/MultipleExpectations
    end

    context "when the suppression window expires" do
      let(:endpoint) { %r{https://api.celerbrake.com/api/v3/projects/1/notices} }

      before do
        stub_request(:post, endpoint).to_return(
          status: 429, body: 'Too Many Requests', headers: { 'Retry-After' => '1' },
        )
        allow(mock_backlog).to receive(:<<)
      end

      # rubocop:disable RSpec/MultipleExpectations
      it "clears the suppressed state at the expected time" do
        sync_sender.send({}, Celerbrake::Promise.new)
        expect(sync_sender).to be_rate_limited

        sleep 1.1
        expect(sync_sender).not_to be_rate_limited
      end
      # rubocop:enable RSpec/MultipleExpectations
    end

    # The reviewer's related concern: a blanket backoff on a header-less 429
    # pauses ALL sends through that sender. The gate is per-sender (errors,
    # performance and deploys each own one) AND now per-endpoint, so a 429
    # minted for one destination cannot silence the others.
    context "when one endpoint rate limits" do
      let(:routes_url) do
        'https://api.celerbrake.com/api/v5/projects/1/routes-stats'
      end
      let(:queries_url) do
        'https://api.celerbrake.com/api/v5/projects/1/queries-stats'
      end

      before do
        stub_request(:post, routes_url).to_return(
          status: 429, body: 'Too Many Requests', headers: { 'Retry-After' => '600' },
        )
        stub_request(:post, queries_url).to_return(body: '{}')
        allow(mock_backlog).to receive(:<<)
      end

      # rubocop:disable RSpec/MultipleExpectations
      it "doesn't suppress sends to other endpoints" do
        sync_sender.send({}, Celerbrake::Promise.new, URI(routes_url))
        sync_sender.send({}, Celerbrake::Promise.new, URI(queries_url))

        expect(a_request(:post, queries_url)).to have_been_made.once
        expect(sync_sender.rate_limited?(URI(routes_url))).to be(true)
      end
      # rubocop:enable RSpec/MultipleExpectations
    end

    context "when the provided method is :put" do
      before { stub_request(:put, endpoint).to_return(status: 200, body: '') }

      it "PUTs the request" do
        sender = described_class.new(:put)
        sender.send({}, promise)
        expect(a_request(:put, endpoint)).to have_been_made
      end
    end

    context "when the provided method is :post" do
      it "POSTs the request" do
        sender = described_class.new(:post)
        sender.send({}, promise)
        expect(a_request(:post, endpoint)).to have_been_made
      end
    end

    described_class::BACKLOGGABLE_STATUS_CODES.each do |status_code|
      context "when the response code is backloggable" do
        before do
          allow(mock_backlog).to receive(:<<)
          allow(Celerbrake::Response).to receive(:parse).and_return('code' => status_code)
        end

        it "sends the data to the backlog when the response is #{status_code}" do
          described_class.new(:post).send(1, promise)
          expect(mock_backlog).to have_received(:<<)
            .with([1, an_instance_of(URI::HTTPS)])
        end
      end
    end

    context "when the response code is not backloggable" do
      before do
        allow(mock_backlog).to receive(:<<)
        allow(Celerbrake::Response).to receive(:parse).and_return('code' => 999)
      end

      it "doesn't send the data to the backlog" do
        described_class.new(:post).send(1, promise)
        expect(mock_backlog).not_to have_received(:<<)
      end
    end
  end

  describe "#close" do
    before { allow(mock_backlog).to receive(:close) }

    it "closes the backlog" do
      sync_sender.close
      expect(mock_backlog).to have_received(:close)
    end
  end

  # DEFECT B regression (timeout half): with `timeout` unset, the sender used
  # to build Net::HTTP with library defaults — 60s open + 60s read per notice.
  # With 1 worker and a queue of 100, an unreachable-but-not-refusing server
  # drained at ~1 notice per 60-120s and the queue blackholed everything else.
  describe "#build_https" do
    let(:uri) { URI('https://api.celerbrake.com/api/v3/projects/1/notices') }

    def build_https
      sync_sender.__send__(:build_https, uri)
    end

    context "when config.timeout is unset (the default)" do
      # rubocop:disable RSpec/MultipleExpectations
      it "applies the default open/read/write timeouts" do
        https = build_https
        expect(https.open_timeout).to eq(Celerbrake::Config::DEFAULT_OPEN_TIMEOUT)
        expect(https.read_timeout).to eq(Celerbrake::Config::DEFAULT_READ_TIMEOUT)
        expect(https.write_timeout).to eq(Celerbrake::Config::DEFAULT_WRITE_TIMEOUT)
      end
      # rubocop:enable RSpec/MultipleExpectations
    end

    context "when config.timeout is set" do
      before { Celerbrake::Config.instance.timeout = 21 }

      # rubocop:disable RSpec/MultipleExpectations
      it "applies it to the open/read/write timeouts" do
        https = build_https
        expect(https.open_timeout).to eq(21)
        expect(https.read_timeout).to eq(21)
        expect(https.write_timeout).to eq(21)
      end
      # rubocop:enable RSpec/MultipleExpectations
    end
  end
end
