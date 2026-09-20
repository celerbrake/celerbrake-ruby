source 'https://rubygems.org'
gemspec

# RuboCop runs in its own `lint` job on one Ruby, not across the test matrix:
# each Ruby in the matrix re-resolves the lockfile and lands on a different
# rubocop (1.28 on Ruby 2.5, 1.91 on 3.4), and no single `.rubocop_todo.yml`
# can be valid for both. rubocop-rspec 3 and rubocop 1.91 both require Ruby
# 2.7, so guard them the same way webrick, rdoc and yard are guarded below,
# or `bundle install` fails outright on the 2.5 and 2.6 jobs.
if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.7')
  gem 'rubocop', '~> 1.91', require: false
  gem 'rubocop-rake', '~> 0.7', require: false
  # rubocop-rspec 2.x drags in rubocop-rspec_rails 2.29, which calls
  # `ConfigLoader.inject_defaults!` with a project root; rubocop 1.91 refuses
  # that and aborts before inspecting a single file. 3.x dropped the
  # dependency entirely.
  gem 'rubocop-rspec', '~> 3.0', require: false
end

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
