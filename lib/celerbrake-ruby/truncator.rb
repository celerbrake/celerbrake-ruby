module Celerbrake
  # This class is responsible for truncation of too big objects. Mainly, you
  # should use it for simple objects such as strings, hashes, & arrays.
  #
  # @api private
  # @since v1.0.0
  class Truncator
    # @return [Hash] the options for +String#encode+
    ENCODING_OPTIONS = { invalid: :replace, undef: :replace }.freeze

    # @return [String] the temporary encoding to be used when fixing invalid
    #   strings with +ENCODING_OPTIONS+
    TEMP_ENCODING = 'utf-16'.freeze

    # @return [Array<Encoding>] encodings that are eligible for fixing invalid
    #   characters
    SUPPORTED_ENCODINGS = [Encoding::UTF_8, Encoding::ASCII].freeze

    # @return [String] what to append when something is a circular reference
    CIRCULAR = '[Circular]'.freeze

    # @return [String] what to append when something is truncated
    TRUNCATED = '[Truncated]'.freeze

    # @return [Array<Class>] The types that can contain references to itself
    CIRCULAR_TYPES = [Array, Hash, Set].freeze

    # @return [Array<Symbol,String>] hash keys that carry the IDENTITY of an
    #   error rather than its payload. Cutting these does not lose detail — it
    #   changes which bug the server thinks it is looking at.
    #
    # `Notice#to_json` HALVES `max_size` (10000, 5000, … 39, 19, 9, 4, 2, 1)
    # until the whole notice fits `MAX_NOTICE_SIZE`, so the cut point measures
    # how big the payload happened to be, not anything about the error. The
    # server fingerprints on exception class + top app frame's file + function,
    # so a payload-driven cut silently mints a NEW error group — and each new
    # group fires `error_group.new` and opens an autonomous triage task.
    #
    # Measured on a real Celerbrake install (2026-07-31): ONE
    # `ActiveRecord::DatabaseConnectionError` existed as FOUR groups —
    # `ActiveRecord::Datab[Truncated]` (10,157 occurrences),
    # `ActiveRec[Truncated]` (2,438), `Acti[Truncated]` (1,155), and one whose
    # class was intact but whose FILE was cut one character early
    # (16,011) — that last being larger than the other three combined.
    # `function` is included on the same reasoning; it is a fingerprint input too.
    IDENTITY_KEYS = %i[type file function].freeze

    # @return [Integer] the smallest `max_size` ever applied to an IDENTITY_KEY.
    #
    # A floor, deliberately NOT an exemption: a key that can never be truncated
    # is a key that can be arbitrarily large, and this runs on the error path of
    # every application that installs the gem. Above the floor these keys shrink
    # normally, so a pathological 100 KB class name is still bounded.
    #
    # 256 is ~2.3x the longest real value observed across 148 production error
    # groups (exception class max 48 / avg 23; top frame file max 113 / avg 40).
    #
    # This CANNOT stop `Notice#to_json` converging: the notice shrinks by
    # dropping array elements and hash entries as well as by cutting strings, and
    # both of those still follow `max_size` all the way down. At budget 1 a
    # backtrace keeps one frame and a hash one key, floor or no floor.
    IDENTITY_FLOOR = 256

    # @param [Integer] max_size maximum size of hashes, arrays and strings
    def initialize(max_size)
      @max_size = max_size
    end

    # Performs deep truncation of arrays, hashes, sets & strings. Uses a
    # placeholder for recursive objects (`[Circular]`).
    #
    # @param [Object] object The object to truncate
    # @param [Set] seen The cache that helps to detect recursion
    # @return [Object] truncated object
    def truncate(object, seen = Set.new)
      if seen.include?(object.object_id)
        return CIRCULAR if CIRCULAR_TYPES.any? { |t| object.is_a?(t) }

        return object
      end
      truncate_object(object, seen << object.object_id)
    end

    # Reduces maximum allowed size of hashes, arrays, sets & strings by half.
    # @return [Integer] current +max_size+ value
    def reduce_max_size
      @max_size /= 2
    end

    private

    def truncate_object(object, seen)
      case object
      when Hash then truncate_hash(object, seen)
      when Array then truncate_array(object, seen)
      when Set then truncate_set(object, seen)
      when String then truncate_string(object)
      when Numeric, TrueClass, FalseClass, Symbol, NilClass then object
      else
        truncate_string(stringify_object(object))
      end
    end

    def truncate_string(str)
      fixed_str = replace_invalid_characters(str)
      return fixed_str if fixed_str.length <= @max_size

      (fixed_str.slice(0, @max_size) + TRUNCATED).freeze
    end

    def stringify_object(object)
      object.to_json
    rescue *Notice::JSON_EXCEPTIONS
      object.to_s
    end

    def truncate_hash(hash, seen)
      truncated_hash = {}
      hash.each_with_index do |(key, val), idx|
        break if idx + 1 > @max_size

        truncated_hash[key] = if identity_key?(key) && val.is_a?(String)
                                truncate_identity_string(val)
                              else
                                truncate(val, seen)
                              end
      end

      truncated_hash.freeze
    end

    # SYMBOL keys only, deliberately. `NestedException#as_json` and
    # `Backtrace.parse` always emit these as Symbols, so a Symbol match hits
    # exactly the gem's own identity fields. Coercing (`key.to_s.to_sym`) would
    # also match a user's params containing a STRING key `"file"` — that is
    # their payload, not our identity, and it should keep truncating normally.
    #
    # No rescue is needed: `Array#include?` on a frozen Symbol array cannot
    # raise for any key type, which matters because this runs while the host
    # app is ALREADY handling an exception.
    def identity_key?(key)
      IDENTITY_KEYS.include?(key)
    end

    def truncate_identity_string(str)
      fixed_str = replace_invalid_characters(str)
      floor = @max_size > IDENTITY_FLOOR ? @max_size : IDENTITY_FLOOR
      return fixed_str if fixed_str.length <= floor

      (fixed_str.slice(0, floor) + TRUNCATED).freeze
    end

    def truncate_array(array, seen)
      array.slice(0, @max_size).map! { |elem| truncate(elem, seen) }.freeze
    end

    def truncate_set(set, seen)
      truncated_set = Set.new

      set.each do |elem|
        truncated_set << truncate(elem, seen)
        break if truncated_set.size >= @max_size
      end

      truncated_set.freeze
    end

    # Replaces invalid characters in a string with arbitrary encoding.
    #
    # @param [String] str The string to replace characters
    # @return [String] a UTF-8 encoded string
    # @see https://github.com/flori/json/commit/3e158410e81f94dbbc3da6b7b35f4f64983aa4e3
    def replace_invalid_characters(str)
      utf8_string = SUPPORTED_ENCODINGS.include?(str.encoding)
      return str if utf8_string && str.valid_encoding?

      temp_str = str.dup
      temp_str.encode!(TEMP_ENCODING, **ENCODING_OPTIONS) if utf8_string
      temp_str.encode!('utf-8', **ENCODING_OPTIONS)
    end
  end
end
