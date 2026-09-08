source 'https://rubygems.org'
gemspec

gem 'rubocop', '~> 1.16', require: false
gem 'rubocop-rake', '~> 0.5', require: false
gem 'rubocop-rspec', '~> 2.3', require: false

gem 'simplecov', '~> 0.16', require: false

gem 'webrick', '~> 1.7' if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.0')
gem 'ostruct' # Not a default gem on Ruby 3.5+/JRuby 10; spec_helper requires it.
# YARD needs rdoc to format rdoc markup, and rdoc stopped being a default gem
# on newer Rubies. Declared ONLY there: unpinned on an older Ruby it resolves
# to rdoc 8.x, which yard 0.9.28 cannot drive — that broke the 2.6 and 3.0
# jobs the moment it was added unconditionally. Same version-guard idiom as
# webrick above; older Rubies keep the default rdoc they already ship.
gem 'rdoc' if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.5')
# yard 0.9.28 cannot drive rdoc 8.x (ToHtml#initialize arity), which is the only
# rdoc available on Ruby 4.1 — so new Rubies need 0.9.45 (dependabot #5). But
# 0.9.45's dependency set will not resolve on Ruby 2.5's RubyGems 2.7/Bundler
# 2.3. One version cannot span 2.5 to 4.1; pick per Ruby, as with rdoc above.
gem 'yard', Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.6') ? '0.9.45' : '0.9.28'
