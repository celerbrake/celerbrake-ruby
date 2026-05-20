# We use Semantic Versioning v2.0.0
# More information: http://semver.org/
module Celerbrake
  # @return [String] the library version
  # @api public
  CELERBRAKE_RUBY_VERSION = '0.1.0'.freeze

  # @return [Hash{Symbol=>String}] the information about the notifier library
  # @since v5.0.0
  # @api public
  NOTIFIER_INFO = {
    name: 'celerbrake-ruby'.freeze,
    version: Celerbrake::CELERBRAKE_RUBY_VERSION,
    url: 'https://github.com/celerbrake/celerbrake-ruby'.freeze,
  }.freeze
end
