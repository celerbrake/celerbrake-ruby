require './lib/celerbrake-ruby/version'

Gem::Specification.new do |s|
  s.name        = 'celerbrake-ruby'
  s.version     = Celerbrake::CELERBRAKE_RUBY_VERSION.dup
  s.summary     = 'Ruby notifier for Celerbrake (self-hosted error tracking)'
  s.description = <<DESC
Celerbrake Ruby is a plain Ruby notifier for Celerbrake (https://celerbrake.com),
a self-hosted, wire-compatible error-tracking service. It provides a minimalist
API for sending any Ruby exception to a Celerbrake dashboard. The library is
extremely lightweight and suits plain Ruby applications well. For apps built with
Rails, Sinatra or any other Rack-compliant framework we offer the celerbrake gem
(https://github.com/celerbrake/celerbrake), which reports unhandled exceptions
automatically and integrates with Resque, Sidekiq, Delayed Job and many more.

Celerbrake Ruby began as a fork of airbrake-ruby
(https://github.com/airbrake/airbrake-ruby) and remains wire-compatible with the
Airbrake v3 notice API; the default host points at Celerbrake rather than a
third-party service.
DESC
  s.author      = 'Celerbrake'
  s.email       = 'support@celerbrake.com'
  s.homepage    = 'https://github.com/celerbrake/celerbrake-ruby'
  s.license     = 'MIT'

  s.require_path = 'lib'
  s.files        = ['lib/celerbrake-ruby.rb', *Dir.glob('lib/**/*')]

  s.required_ruby_version = '>= 2.5'
  s.metadata = {
    'rubygems_mfa_required' => 'true',
  }

  if defined?(JRuby)
    s.add_dependency 'rbtree-jruby', '~> 0.2'
  else
    s.add_dependency 'rbtree3', '~> 0.6'
  end

  # base64 and logger left the default gem set in Ruby 3.4; declare them so the
  # notifier keeps working on modern Rubies.
  s.add_dependency 'base64'
  s.add_dependency 'logger'

  s.add_development_dependency 'rspec', '~> 3'
  s.add_development_dependency 'rspec-its', '~> 1.2'
  s.add_development_dependency 'rake', '~> 13'
  s.add_development_dependency 'pry', '~> 0'
  s.add_development_dependency 'webmock', '~> 3.8'
  s.add_development_dependency 'benchmark-ips', '~> 2'
  s.add_development_dependency 'yard', '~> 0.9'
end
