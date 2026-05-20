module Celerbrake
  # Ignorable contains methods that allow the includee to be ignored.
  #
  # @example
  #   class A
  #     include Celerbrake::Ignorable
  #   end
  #
  #   a = A.new
  #   a.ignore!
  #   a.ignored? #=> true
  #
  # @since v3.2.0
  # @api private
  module Ignorable
    attr_accessor :ignored

    # Checks whether the instance was ignored.
    # @return [Boolean]
    # @see #ignore!
    def ignored?
      !!ignored
    end

    # Ignores an instance. Ignored instances must never reach the Celerbrake
    # dashboard.
    # @return [void]
    # @see #ignored?
    def ignore!
      self.ignored = true
    end

    private

    # A method that is meant to be used as a guard.
    # @raise [Celerbrake::Error] when instance is ignored
    def raise_if_ignored
      return unless ignored?

      raise Celerbrake::Error, "cannot access ignored #{self.class}"
    end
  end
end
