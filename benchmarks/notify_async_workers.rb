require_relative 'benchmark_helpers'

# The number of notices to process.
NOTICES = 1200

cores =
  case RbConfig::CONFIG['host_os']
  when /linux/
    Dir.glob('/sys/devices/system/cpu/cpu[0-9]*').count
  when /darwin|bsd/
    Integer(`sysctl -n hw.ncpu`)
  else
    2
  end

double_cores = 2 * cores

config_hash = {
  project_id: 112261,
  project_key: 'c7aaceb2ccb579e6b710cea9da22c526',
  logger: Logger.new('/dev/null'),
  host: 'http://localhost:8080',
}

Celerbrake.configure(:workers_1) do |c|
  c.merge(config_hash.merge(workers: 1))
end

Celerbrake.configure(:"workers_#{cores}") do |c|
  c.merge(config_hash.merge(workers: cores))
end

Celerbrake.configure(:"workers_#{double_cores}") do |c|
  c.merge(config_hash.merge(workers: double_cores))
end

def notify_via(notifier)
  NOTICES.times do
    Celerbrake.notify(BIG_EXCEPTION, {}, notifier)
  end

  Celerbrake.close(notifier)
end

# Don't forget to run the server: go run benchmarks/server.go
Benchmark.bm do |bm|
  bm.report("1 worker  Celerbrake.notify") do
    notify_via(:workers_1)
  end

  bm.report("#{cores} workers Celerbrake.notify") do
    notify_via(:"workers_#{cores}")
  end

  bm.report("#{double_cores} workers Celerbrake.notify") do
    notify_via(:"workers_#{double_cores}")
  end
end
