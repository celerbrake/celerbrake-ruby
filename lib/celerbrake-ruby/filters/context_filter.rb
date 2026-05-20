module Celerbrake
  module Filters
    # Adds user context to the notice object. Clears the context after it's
    # attached.
    #
    # @api private
    # @since v2.9.0
    class ContextFilter
      # @return [Integer]
      attr_reader :weight

      def initialize
        @weight = 119
        @mutex = Mutex.new
      end

      # @macro call_filter
      def call(notice)
        @mutex.synchronize do
          return if Celerbrake::Context.current.empty?

          notice[:params][:celerbrake_context] = Celerbrake::Context.current.to_h
          Celerbrake::Context.current.clear
        end
      end
    end
  end
end
