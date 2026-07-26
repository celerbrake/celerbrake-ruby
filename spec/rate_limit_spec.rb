RSpec.describe Celerbrake::RateLimit do
  subject(:rate_limit) { described_class.new }

  let(:endpoint) { 'https://api.celerbrake.com/api/v3/projects/1/notices' }

  describe "#suppress" do
    it "reports the endpoint as suppressed until the given time" do
      reset = Time.now + 30
      rate_limit.suppress(endpoint, reset)

      expect(rate_limit.reset_at(endpoint)).to eq(reset)
    end

    it "doesn't suppress other endpoints" do
      rate_limit.suppress(endpoint, Time.now + 30)

      expect(rate_limit.suppressed?("#{endpoint}-other")).to be(false)
    end

    it "stops suppressing once the window has passed" do
      rate_limit.suppress(endpoint, Time.now - 1)

      expect(rate_limit.suppressed?(endpoint)).to be(false)
    end

    # The map is keyed by endpoint, and a backlog can replay payloads for
    # endpoints that no longer exist. Expired windows must not accumulate.
    it "prunes expired windows instead of growing without bound" do
      (described_class::MAX_TRACKED_ENDPOINTS + 10).times do |i|
        rate_limit.suppress("#{endpoint}/#{i}", Time.now - 1)
      end

      tracked = rate_limit.instance_variable_get(:@resets)
      expect(tracked.size).to be <= described_class::MAX_TRACKED_ENDPOINTS
    end

    it "keeps live windows while pruning" do
      live = Time.now + 60
      rate_limit.suppress(endpoint, live)
      (described_class::MAX_TRACKED_ENDPOINTS + 10).times do |i|
        rate_limit.suppress("#{endpoint}/#{i}", Time.now - 1)
      end

      expect(rate_limit.reset_at(endpoint)).to eq(live)
    end
  end

  describe "#note_drop" do
    it "counts every drop" do
      reset = Time.now + 30
      10.times { rate_limit.note_drop(endpoint, reset) }

      expect(rate_limit.drops).to eq(10)
    end

    it "logs at most one line per LOG_INTERVAL" do
      allow(Celerbrake::Loggable.instance).to receive(:warn)
      reset = Time.now + 30

      10.times { rate_limit.note_drop(endpoint, reset) }

      expect(Celerbrake::Loggable.instance).to have_received(:warn).once
    end

    it "names the endpoint and the time sends resume" do
      allow(Celerbrake::Loggable.instance).to receive(:warn)
      reset = Time.now + 30

      rate_limit.note_drop(endpoint, reset)

      expect(Celerbrake::Loggable.instance).to have_received(:warn).with(
        /suppressing sends to #{Regexp.escape(endpoint)} until #{reset.getutc.iso8601}/,
      )
    end

    it "doesn't block concurrent droppers" do
      reset = Time.now + 30
      threads = Array.new(8) do
        Thread.new { 100.times { rate_limit.note_drop(endpoint, reset) } }
      end

      threads.each { |thread| expect(thread.join(5)).to eq(thread) }
    end
  end
end
