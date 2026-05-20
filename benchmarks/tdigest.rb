require_relative 'benchmark_helpers'

Benchmark.ips do |ips|
  ips.report do
    tdigest = Celerbrake::TDigest.new(0.05)
    100.times { tdigest.push(rand(1..200)) }
    tdigest.compress!
  end
end
