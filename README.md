# Celerbrake Ruby

**Celerbrake Ruby** is a lightweight, dependency-light Ruby notifier for
[Celerbrake][celerbrake] — a self-hosted error- and exception-tracking service.
It captures Ruby exceptions and ships them to a Celerbrake instance, where they
are grouped, de-duplicated, and rendered with full backtraces, occurrence
timelines, and request context.

This gem is the plain-Ruby core. If you run Rails, Sinatra, or any other
Rack-compliant framework, use the higher-level [`celerbrake`][celerbrake-gem]
gem instead — it depends on this one and wires up automatic, unhandled-exception
reporting plus integrations with ActiveJob, Sidekiq, Resque, Delayed Job, and
more.

> **Heritage.** Celerbrake Ruby began life as a fork of
> [airbrake-ruby][airbrake-ruby] (v6.2.1) and stays wire-compatible with the
> Airbrake v3 `create-notice` API. The substantive difference is that the
> default reporting host is `https://api.celerbrake.com` instead of a
> third-party service, so you control the whole pipeline. We are grateful to
> Airbrake Technologies, Inc. for the original, MIT-licensed work — see
> [LICENSE.md](LICENSE.md).

## Installation

### Bundler

```ruby
gem 'celerbrake-ruby'
```

### Manual

```bash
gem install celerbrake-ruby
```

## Key features

- Asynchronous (and synchronous) exception reporting with a background worker
  pool and bounded queue
- Automatic backtrace parsing, code-hunk extraction, and root-directory
  trimming
- A flexible [filter chain](#adding-filters) for adding context, ignoring
  notices, or redacting sensitive data before it leaves your process
- Built-in redaction of common secret-shaped keys
  (`password`, `secret`, `*_token`, `authorization`, ...)
- Minimal dependencies; suitable for plain Ruby scripts, daemons, and gems

## Configuration

Before sending notices, configure the notifier with the **project id** and
**project key** issued by your Celerbrake instance (created at
`/admin/projects` on the server).

```ruby
require 'celerbrake-ruby'

Celerbrake.configure do |c|
  c.project_id  = 123
  c.project_key = 'fa0123456789abcdef0123456789abcd'

  # Defaults to https://api.celerbrake.com. Point this at your own instance.
  c.host = 'https://errors.example.com'

  # Report only from these environments.
  c.environment         = ENV['RACK_ENV']
  c.ignore_environments = %w[development test]
end
```

### Notable configuration options

| Option | Default | Description |
| --- | --- | --- |
| `project_id` | `nil` | Numeric project id from the Celerbrake admin page. **Required.** |
| `project_key` | `nil` | Project API key from the Celerbrake admin page. **Required.** |
| `host` | `https://api.celerbrake.com` | Base URL of the Celerbrake instance receiving notices. |
| `environment` | `nil` | Current environment name (e.g. `production`). |
| `ignore_environments` | `[]` | Environments from which notices are dropped. |
| `root_directory` | app root | Used to trim and group backtrace frames. |
| `blocklist_keys` | `[]` | Keys whose values are redacted before sending. |
| `allowlist_keys` | `[]` | If set, only these keys are sent; everything else is redacted. |
| `remote_config` | `false` | Off by default — Celerbrake does not serve a remote-config endpoint. |

## Operational behavior

This notifier runs inside your app's request path, so it is built to fail
quietly and *bounded* rather than to hold a thread hostage:

- **`Celerbrake.notify` never blocks.** The background queue is bounded; when
  it is full the notice is dropped, counted (`ThreadPool#dropped_count`) and
  logged at most once every 10 seconds.
- **Every HTTP call is bounded.** With `config.timeout` unset the notifier uses
  open 2s / read 5s / write 5s. Setting `config.timeout` overrides all three.
- **A 429 always backs off — for a bounded time.** The delay comes from
  `Retry-After` (delta-seconds or HTTP-date), then the legacy
  `X-RateLimit-Delay`, then a 60s default (`Response::DEFAULT_RATE_LIMIT_DELAY`).

### Rate-limit backoff is clamped and observable

A 429 can come from anything on the path — a proxy, a WAF, a CDN, a
misconfigured load balancer — not just from Celerbrake, so the notifier does
not let a response header decide how long your app stops reporting:

| Response says | Notifier honors |
| --- | --- |
| `Retry-After: 30` | 30s |
| `Retry-After: 86400` (or a date days out) | 900s — `Response::MAX_RATE_LIMIT_DELAY` |
| `Retry-After: -500`, `garbage`, or a past date | 60s — `Response::DEFAULT_RATE_LIMIT_DELAY` |
| nothing | 60s |

**15 minutes** is the ceiling because Celerbrake rate limits per minute, so any
legitimate relief window is minute-scale — while a bogus value can cost you at
most a quarter hour of reporting, never a shift.

Suppression is tracked per sender **and per endpoint** (errors, performance and
deploys use separate senders), so a 429 minted for one destination cannot
silence the others. While suppressed, the notifier logs one line per 10 seconds
and exposes the state, so an operator — or an agent asking "why did this app go
quiet?" — can tell that reporting is paused and until when:

```ruby
sender.rate_limited?      #=> true
sender.rate_limit_reset   #=> 2026-07-26 18:04:11 UTC (when sends resume)
sender.rate_limited_drops #=> 412 (payloads dropped since startup)
```

## Usage

### Sending a notice

```ruby
begin
  raise 'Oops!'
rescue => exception
  Celerbrake.notify(exception)
end
```

`Celerbrake.notify` is asynchronous and returns a promise. Use
`Celerbrake.notify_sync` when you need to block until the notice is delivered
(e.g. in a one-off script or a Rake task):

```ruby
Celerbrake.notify_sync(StandardError.new('hello from a script'))
```

### Adding context

```ruby
Celerbrake.notify(exception) do |notice|
  notice[:context][:user] = { id: 42, email: 'user@example.com' }
  notice[:params][:document_id] = document.id
end
```

### Adding filters

Filters run on every notice and can mutate it, add context, or ignore it
entirely:

```ruby
# Ignore a class of errors.
Celerbrake.add_filter do |notice|
  notice.ignore! if notice[:errors].any? { |e| e[:type] == 'PageNotFound' }
end

# Redact a custom sensitive key.
Celerbrake.blocklist_keys << /credit_card/i
```

## Supported Ruby versions

Celerbrake Ruby supports Ruby 2.5+ (matching its upstream baseline). CI targets
current stable Ruby releases.

## Contributing

Bug reports and pull requests are welcome. Run the test suite with:

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

Celerbrake Ruby is released under the [MIT License](LICENSE.md). It is a
derivative work of [airbrake-ruby][airbrake-ruby], also MIT-licensed; the
original copyright is preserved in `LICENSE.md`.

[celerbrake]:     https://celerbrake.com
[celerbrake-gem]: https://github.com/celerbrake/celerbrake
[airbrake-ruby]:  https://github.com/airbrake/airbrake-ruby
