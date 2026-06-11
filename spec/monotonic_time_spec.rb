RSpec.describe Celerbrake::MonotonicTime do
  subject(:monotonic_time) { described_class }

  describe ".time_in_ms" do
    it "returns monotonic time in milliseconds" do
      expect(monotonic_time.time_in_ms).to be_a(Float)
    end

    it "never goes backwards" do
      # Two consecutive reads can be EQUAL at clock resolution on a fast
      # machine — monotonic means non-decreasing, not strictly increasing
      # (this was a real intermittent failure).
      old_time = monotonic_time.time_in_ms
      expect(monotonic_time.time_in_ms).to be >= old_time
    end
  end

  describe ".time_in_s" do
    it "returns monotonic time in seconds" do
      expect(monotonic_time.time_in_s).to be_a(Float)
    end

    it "never goes backwards" do
      old_time = monotonic_time.time_in_s
      expect(monotonic_time.time_in_s).to be >= old_time
    end
  end
end
