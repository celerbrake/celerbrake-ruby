Celerbrake Ruby Changelog
=========================

### master

- No pending changes to be released

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
