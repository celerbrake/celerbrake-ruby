module Celerbrake
  module Filters
    # A default Celerbrake notice filter. Filters only specific keys listed in the
    # list of parameters in the payload of a notice.
    #
    # @example
    #   filter = Celerbrake::Filters::KeysBlocklist.new(
    #     [:email, /credit/i, 'password']
    #   )
    #   celerbrake.add_filter(filter)
    #   celerbrake.notify(StandardError.new('App crashed!'), {
    #     user: 'John'
    #     password: 's3kr3t',
    #     email: 'john@example.com',
    #     credit_card: '5555555555554444'
    #   })
    #
    #   # The dashboard will display this parameter as is, but all other
    #   # values will be filtered:
    #   #   { user: 'John',
    #   #     password: '[Filtered]',
    #   #     email: '[Filtered]',
    #   #     credit_card: '[Filtered]' }
    #
    # @see KeysAllowlist
    # @see KeysFilter
    # @api private
    class KeysBlocklist
      include KeysFilter

      def initialize(*)
        super
        @weight = -110
      end

      # @return [Boolean] true if the key matches at least one pattern, false
      #   otherwise
      def should_filter?(key)
        @patterns.any? do |pattern|
          if pattern.is_a?(Regexp)
            key.match(pattern)
          else
            key.to_s == pattern.to_s
          end
        end
      end
    end
  end
end
