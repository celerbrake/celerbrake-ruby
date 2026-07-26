Celerbrake Ruby Changelog
=========================

### master

- **Notify never blocks the host app.** `ThreadPool#<<` now pushes
  non-blockingly: the old check-then-push allowed two request threads to both
  observe a nearly-full queue and both push, leaving the loser asleep inside
  `Celerbrake.notify` until a worker popped — during an outage that hung host
  request threads for the duration of the HTTP call. Overflow now drops the
  message, counts it (`ThreadPool#dropped_count`) and logs at most one line
  per 10 seconds. `ThreadPool#close` also pushes its `:stop` sentinels outside
  the internal mutex so a draining shutdown can no longer wedge the notify
  path behind `has_workers?`.
- **HTTP calls are bounded by default.** When `config.timeout` is unset, the
  senders and the remote-settings poller now apply default timeouts (open 2s,
  read 5s, write 5s — `Config::DEFAULT_OPEN_TIMEOUT` /
  `DEFAULT_READ_TIMEOUT` / `DEFAULT_WRITE_TIMEOUT`) instead of inheriting
  Net::HTTP's 60-second defaults, which let an unreachable server drain the
  notice queue at ~1 notice per 60-120s while everything else blackholed.
  Setting `config.timeout` still overrides all three at once.
- **429 responses always back off.** The rate-limit delay now honors the
  standard `Retry-After` header (delta-seconds or HTTP-date), then the legacy
  `X-RateLimit-Delay`, then falls back to 60s — and a non-JSON 429 body no
  longer defeats the backoff (it used to drop the `rate_limit_reset` key and
  hot-retry a server that was shedding load).

### [v0.1.0][v0.1.0] (unreleased)

Initial release of Celerbrake Ruby.

Celerbrake Ruby is a fork of [airbrake-ruby][airbrake-ruby] v6.2.1. Changes from
the upstream notifier:

- Renamed the `Airbrake` module and the `airbrake-ruby` gem to `Celerbrake` /
  `celerbrake-ruby`.
- Changed the default `error_host` / `apm_host` from `https://api.airbrake.io`
  to `https://api.celerbrake.com`.
- Defaulted `remote_config` to `false` (Celerbrake does not serve a remote-config
  endpoint yet, so the notifier no longer polls a host you don't control).
- Otherwise wire-compatible with the Airbrake v3 `create-notice` API.

For the full history of the upstream notifier prior to the fork, see the
[airbrake-ruby CHANGELOG][upstream-changelog].

[airbrake-ruby]: https://github.com/airbrake/airbrake-ruby
[upstream-changelog]: https://github.com/airbrake/airbrake-ruby/blob/master/CHANGELOG.md
