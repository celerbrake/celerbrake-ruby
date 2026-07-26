RSpec.describe Celerbrake::Response do
  describe ".parse" do
    [200, 201, 204].each do |code|
      context "when response code is #{code}" do
        before do
          allow(Celerbrake::Loggable.instance).to receive(:debug)
        end

        it "logs response body" do
          described_class.parse(OpenStruct.new(code: code, body: '{}'))

          expect(Celerbrake::Loggable.instance).to have_received(:debug).with(
            /Celerbrake::Response \(#{code}\): {}/,
          )
        end
      end
    end

    [400, 401, 403, 420].each do |code|
      context "when response code is #{code}" do
        before do
          allow(Celerbrake::Loggable.instance).to receive(:error)
        end

        it "logs response message" do
          described_class.parse(
            OpenStruct.new(code: code, body: '{"message":"foo"}'),
          )

          expect(Celerbrake::Loggable.instance).to have_received(:error).with(
            /Celerbrake: foo/,
          )
        end
      end
    end

    context "when response code is 429" do
      let(:response) { OpenStruct.new(code: 429, body: '{"message":"rate limited"}') }

      before do
        allow(Celerbrake::Loggable.instance).to receive(:error)
      end

      it "logs response message" do
        described_class.parse(response)
        expect(Celerbrake::Loggable.instance).to have_received(:error).with(
          /Celerbrake: rate limited/,
        )
      end

      it "returns an error response with a fallback backoff delay" do
        time = Time.now
        allow(Time).to receive(:now).and_return(time)

        resp = described_class.parse(response)
        expect(resp).to include(
          'error' => '**Celerbrake: rate limited',
          # No Retry-After and no X-RateLimit-Delay: a 429 must still result
          # in a backoff, never a hot-retry on the next notice.
          'rate_limit_reset' => time + described_class::DEFAULT_RATE_LIMIT_DELAY,
        )
      end

      context "with a Retry-After header in delta-seconds" do
        let(:response) do
          OpenStruct.new(
            code: 429, body: '{"message":"rate limited"}', 'Retry-After' => '7'
          )
        end

        it "honors Retry-After" do
          time = Time.now
          allow(Time).to receive(:now).and_return(time)

          resp = described_class.parse(response)
          expect(resp).to include('rate_limit_reset' => time + 7)
        end
      end

      context "with a Retry-After header as an HTTP-date" do
        let(:time) { Time.now }
        let(:response) do
          OpenStruct.new(
            code: 429,
            body: '{"message":"rate limited"}',
            'Retry-After' => (time + 120).utc.httpdate,
          )
        end

        it "honors Retry-After" do
          allow(Time).to receive(:now).and_return(time)

          resp = described_class.parse(response)
          expect(resp['rate_limit_reset']).to be_within(2).of(time + 120)
        end
      end

      context "with a legacy X-RateLimit-Delay header" do
        let(:response) do
          OpenStruct.new(
            code: 429, body: '{"message":"rate limited"}', 'X-RateLimit-Delay' => '3'
          )
        end

        it "honors X-RateLimit-Delay" do
          time = Time.now
          allow(Time).to receive(:now).and_return(time)

          resp = described_class.parse(response)
          expect(resp).to include('rate_limit_reset' => time + 3)
        end
      end

      # BLOCKER regression (unbounded backoff): a 429 can be minted by ANY
      # intermediary — a proxy, a WAF, a CDN, a misconfigured load balancer —
      # not just by Celerbrake. Honoring its Retry-After verbatim let a single
      # hostile or fat-fingered header silence a project's entire error
      # reporting for hours or days, precisely while an operator believed the
      # app was reporting. The honored backoff is now clamped.
      context "with an absurd Retry-After in delta-seconds" do
        let(:response) do
          OpenStruct.new(
            code: 429, body: '{"message":"rate limited"}', 'Retry-After' => '86400'
          )
        end

        it "clamps the backoff to MAX_RATE_LIMIT_DELAY" do
          time = Time.now
          allow(Time).to receive(:now).and_return(time)

          resp = described_class.parse(response)
          expect(resp['rate_limit_reset'])
            .to eq(time + described_class::MAX_RATE_LIMIT_DELAY)
        end
      end

      context "with a Retry-After HTTP-date a week in the future" do
        let(:time) { Time.now }
        let(:response) do
          OpenStruct.new(
            code: 429,
            body: '{"message":"rate limited"}',
            'Retry-After' => (time + (7 * 24 * 60 * 60)).utc.httpdate,
          )
        end

        it "clamps the backoff to MAX_RATE_LIMIT_DELAY" do
          allow(Time).to receive(:now).and_return(time)

          resp = described_class.parse(response)
          expect(resp['rate_limit_reset'])
            .to be_within(2).of(time + described_class::MAX_RATE_LIMIT_DELAY)
        end
      end

      context "with a hostile, oversized Retry-After" do
        let(:response) do
          OpenStruct.new(
            code: 429, body: '{"message":"rate limited"}', 'Retry-After' => '9' * 500
          )
        end

        # rubocop:disable RSpec/MultipleExpectations
        it "never honors more than MAX_RATE_LIMIT_DELAY" do
          time = Time.now
          allow(Time).to receive(:now).and_return(time)

          resp = described_class.parse(response)
          expect(resp['rate_limit_reset']).to be > time
          expect(resp['rate_limit_reset'])
            .to be <= time + described_class::MAX_RATE_LIMIT_DELAY
        end
        # rubocop:enable RSpec/MultipleExpectations
      end

      context "with an absurd legacy X-RateLimit-Delay" do
        let(:response) do
          OpenStruct.new(
            code: 429,
            body: '{"message":"rate limited"}',
            'X-RateLimit-Delay' => '86400',
          )
        end

        it "clamps the backoff to MAX_RATE_LIMIT_DELAY" do
          time = Time.now
          allow(Time).to receive(:now).and_return(time)

          resp = described_class.parse(response)
          expect(resp['rate_limit_reset'])
            .to eq(time + described_class::MAX_RATE_LIMIT_DELAY)
        end
      end

      # BLOCKER regression (garbage in): a malformed, negative or stale
      # Retry-After must fall back to the documented default — never to a
      # negative (instant hot-retry) or unbounded sleep.
      [
        ['a malformed value', 'not-a-number'],
        ['a negative value', '-500'],
        ['an empty value', '   '],
        ['a float-looking value', '3600.5'],
        ['an HTTP-date in the past', 'Wed, 21 Oct 2015 07:28:00 GMT'],
      ].each do |description, header|
        context "with #{description} in Retry-After" do
          let(:response) do
            OpenStruct.new(
              code: 429, body: '{"message":"rate limited"}', 'Retry-After' => header
            )
          end

          it "falls back to DEFAULT_RATE_LIMIT_DELAY" do
            time = Time.now
            allow(Time).to receive(:now).and_return(time)

            resp = described_class.parse(response)
            expect(resp['rate_limit_reset'])
              .to eq(time + described_class::DEFAULT_RATE_LIMIT_DELAY)
          end
        end
      end

      # DEFECT B regression (backoff half): 429 bodies aren't guaranteed to
      # be JSON (rack throttles send plain text). The old implementation let
      # JSON::ParserError fall into the generic rescue, which dropped the
      # 'rate_limit_reset' key — so the client hot-retried a server that was
      # telling it to slow down.
      context "with a non-JSON body" do
        let(:response) do
          OpenStruct.new(code: 429, body: 'Too Many Requests', 'Retry-After' => '30')
        end

        # rubocop:disable RSpec/MultipleExpectations
        it "still returns a rate_limit_reset so the client backs off" do
          time = Time.now
          allow(Time).to receive(:now).and_return(time)

          resp = described_class.parse(response)
          expect(resp['rate_limit_reset']).to eq(time + 30)
          expect(resp['error']).to match(/Too Many Requests/)
        end
        # rubocop:enable RSpec/MultipleExpectations
      end
    end

    context "when response code is unhandled" do
      let(:response) { OpenStruct.new(code: 500, body: 'foo') }

      before do
        allow(Celerbrake::Loggable.instance).to receive(:error)
      end

      it "logs response body" do
        described_class.parse(response)
        expect(Celerbrake::Loggable.instance).to have_received(:error).with(
          /Celerbrake: unexpected code \(500\)\. Body: foo/,
        )
      end

      it "returns an error response" do
        resp = described_class.parse(response)
        expect(resp).to eq('code' => 500, 'error' => 'foo')
      end

      it "truncates body" do
        response.body *= 1000
        resp = described_class.parse(response)
        expect(resp).to eq('code' => 500, 'error' => "#{'foo' * 33}fo...")
      end
    end

    context "when response body can't be parsed as JSON" do
      let(:response) { OpenStruct.new(code: 201, body: 'foo') }

      before do
        allow(Celerbrake::Loggable.instance).to receive(:error)
      end

      it "logs response body" do
        described_class.parse(response)
        expect(Celerbrake::Loggable.instance).to have_received(:error).with(
          /Celerbrake: error while parsing body \(.*unexpected token.*\)\. Body: foo/,
        )
      end

      it "returns an error message" do
        expect(described_class.parse(response)['error']).to match(
          /\A#<JSON::ParserError.+>/,
        )
      end
    end
  end
end
