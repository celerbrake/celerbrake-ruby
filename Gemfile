source 'https://rubygems.org'
gemspec

gem 'rubocop', '~> 1.16', require: false
gem 'rubocop-rake', '~> 0.5', require: false
gem 'rubocop-rspec', '~> 2.3', require: false

gem 'simplecov', '~> 0.16', require: false

gem 'webrick', '~> 1.7' if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.0')
gem 'ostruct' # Not a default gem on Ruby 3.5+/JRuby 10; spec_helper requires it.
gem 'yard', '0.9.28'
