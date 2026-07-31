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

    # @return [Array<Symbol>] hash keys that carry the IDENTITY of an error
    #   rather than its payload — but ONLY inside the notice subtree this gem
    #   authors itself (`Notice::IDENTITY_SUBTREE`, i.e. `errors`). Everywhere
    #   else — a user's params, session or environment — a key called `:type`
    #   or `:file` is ordinary data and MUST keep truncating normally. That is
    #   the difference between {#truncate} and {#truncate_identity_subtree}.
    #
    # `Notice#to_json` HALVES `max_size` (10000, 5000, … 39, 19, 9, 4, 2, 1)
    # until the whole notice fits `MAX_NOTICE_SIZE`, so where the notice lands
    # on that ladder measures how big the payload happened to be, not anything
    # about the error. The server fingerprints on exception class + the top
    # IN-APP frame's file + function, so a payload-driven cut silently mints a
    # NEW error group — and each new group fires `error_group.new` and opens an
    # autonomous triage task.
    #
    # There are TWO mechanisms, and `type` and `file`/`function` are hit by
    # different ones:
    #
    #   * STRING CUTTING shortens the exception class: at budget 19 a real
    #     production group carries `ActiveRecord::Datab[Truncated]`, at 9
    #     `ActiveRec[Truncated]`, at 4 `Acti[Truncated]`.
    #   * FRAME DROPPING is what moves the frame: `#truncate_array` slices the
    #     backtrace to `max_size` frames, so a low rung DELETES the in-app frame
    #     and the server falls back to the first gem frame. Flooring the strings
    #     does not put the frame back — it only stops the surviving frame's path
    #     from being cut at a payload-dependent point.
    #
    # Measured against the server's real `Fingerprint.for` over production
    # occurrence 109773 (group 69, 122 frames, in-app frame at ordinal 53),
    # replaying budgets 122/78/39/19/9/4 (2026-07-31):
    #
    #   flooring nothing         -> 5 distinct fingerprints from 6 budgets
    #   flooring `type` alone    -> 5 distinct fingerprints  (no improvement)
    #   flooring type+file+func  -> 2 distinct fingerprints
    #
    # That counterfactual — not any claim that two production groups carry the
    # same frame — is why `file` and `function` are in this list. They do NOT
    # carry the same frame. Sampling the 2,000 most recent occurrences of the
    # five groups this one bug produced shows frame counts that ARE the ladder's
    # rungs, and only the uncut group keeping an in-app frame at all:
    #
    #   group  sampled  with an in-app frame  frames
    #     67        58                     0       9
    #     68       184                     0      19
    #     69      1377                  1377  78-123
    #     70       351                     0      39
    #     71        30                     0       4
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
    # It is a CHARACTER floor, like every other length in this class, so the
    # BYTE cost is up to 4x it — ~1 KB for an identity value made entirely of
    # 4-byte UTF-8. At budget `b` the errors subtree retains at most `b` errors
    # x (1 class + `b` frames x 2 fields) floored strings, i.e. O(b^2), so the
    # worst case shrinks fast as the ladder descends and the floor CANNOT stop
    # `Notice#to_json` converging: the notice also shrinks by dropping array
    # elements and hash entries, and both of those still follow `max_size` all
    # the way down. At budget 1 a backtrace keeps one frame and a hash one key,
    # floor or no floor.
    #
    # KNOWN COST, ACCEPTED AND BOUNDED — the floor makes `Notice#to_json`
    # give up (return nil, after `Notice#truncate` logs the payload at ERROR)
    # very slightly EARLIER than the unfloored gem does, so there is a narrow
    # band of payload sizes that the unfloored gem delivered and this one
    # drops. Its width is provable, not empirical.
    #
    # `Notice#to_json` checks the payload BEFORE each truncation pass, so the
    # last state it ever measures is the one truncated at budget **2** (the
    # budget-1 pass is applied and then discarded when `reduce_max_size`
    # returns 0 and the loop breaks). At budget 2 `#truncate_array` slices
    # `errors` to 2 entries and `#truncate_hash` keeps each entry's first 2
    # keys — `type` and `message` out of `NestedException#as_json`. So AT MOST
    # TWO floored strings can exist at the deciding moment, whatever the
    # backtrace looks like: `backtrace` is the third key and is already gone.
    #
    #   band <= 2 x ((IDENTITY_FLOOR + TRUNCATED.length) - (2 + TRUNCATED.length))
    #        =  2 x (IDENTITY_FLOOR - 2)  =  508 bytes
    #
    # Measured (Ruby 3.3.10, 7-char hostname, largest `root_directory` that
    # still yields a non-nil `to_json`, two-deep `cause` chain, class-name
    # length L):
    #
    #     L        0f8956b   this tree   band
    #     12         63563      63565      -2   <- floor DELIVERS where unfixed drops
    #     48         63563      63493      70   <- production max observed
    #    100         63563      63389     174
    #    256         63563      63077     486
    #    267+        63563      63055     508   <- saturates, cannot grow
    #
    # With a single (uncaused) exception every number halves. The band is
    # NEGATIVE for class names <= 12 chars, because the floor keeps
    # `RuntimeError` (12) where cutting produces `R[Truncated]` (13).
    #
    # Reaching the band at all requires the notice to be ~99.2% content that
    # truncation cannot touch: `Notice#context` is built once in `#initialize`
    # and is absent from {Notice::TRUNCATABLE_KEYS}, so `rootDirectory`,
    # `versions` and `error_message` never shrink. Saturating it additionally
    # requires a >= 267-character exception class name, against a production
    # maximum of 48 across 148 groups.
    #
    # NOT closing this band is deliberate. The only available remedy — a final
    # unfloored pass before giving up — would, exactly in the regime where it
    # fires, deliver a notice whose `type` is `Ex[Truncated]`: a
    # payload-size-dependent fingerprint, i.e. a brand-new spurious error
    # group, an `error_group.new` alert and an autonomous triage task. That is
    # the defect this floor exists to prevent, so the remedy trades one logged
    # drop for one fabricated error group. `truncator_spec` pins the bound.
    IDENTITY_FLOOR = 256

    # @param [Integer] max_size maximum size of hashes, arrays and strings
    def initialize(max_size)
      @max_size = max_size
    end

    # Performs deep truncation of arrays, hashes, sets & strings. Uses a
    # placeholder for recursive objects (`[Circular]`).
    #
    # THE SIGNATURE IS LOAD-BEARING and must stay free of keyword parameters.
    # A symbol-keyed Hash literal at a call site — `truncate(rows: [1])`, the
    # shape used all over this gem's own specs and benchmarks — parses as
    # KEYWORDS the moment the method declares any, and the call blows up with
    # `ArgumentError: wrong number of arguments (given 0, expected 1..2)`. On
    # the Ruby 2.5–2.7 the gemspec still supports, a symbol-keyed Hash
    # *variable* converts too, which widens the hazard past literals. So the
    # gem-authored scope is carried by a SECOND METHOD rather than by a
    # keyword or a positional flag: no boolean trap at the call site, no
    # `Set.new` for the caller to accidentally hoist out of a loop, and this
    # method's arity stays byte-identical to every released version.
    #
    # @param [Object] object The object to truncate
    # @param [Set] seen The cache that helps to detect recursion
    # @return [Object] truncated object
    def truncate(object, seen = Set.new)
      truncate_scoped(object, seen, false)
    end

    # Same as {#truncate}, but declares that +object+ is a subtree THIS GEM
    # authored, so {IDENTITY_KEYS} found inside it are the error's identity
    # and get {IDENTITY_FLOOR}. Only {Notice::IDENTITY_SUBTREE} qualifies;
    # anything a host application supplied must go through {#truncate}.
    #
    # @param [Object] object The object to truncate
    # @param [Set] seen The cache that helps to detect recursion
    # @return [Object] truncated object
    def truncate_identity_subtree(object, seen = Set.new)
      truncate_scoped(object, seen, true)
    end

    # Reduces maximum allowed size of hashes, arrays, sets & strings by half.
    # @return [Integer] current +max_size+ value
    def reduce_max_size
      @max_size /= 2
    end

    private

    def truncate_scoped(object, seen, identity)
      if seen.include?(object.object_id)
        return CIRCULAR if CIRCULAR_TYPES.any? { |t| object.is_a?(t) }

        return object
      end
      truncate_object(object, seen << object.object_id, identity)
    end

    def truncate_object(object, seen, identity)
      case object
      when Hash then truncate_hash(object, seen, identity)
      when Array then truncate_array(object, seen, identity)
      when Set then truncate_set(object, seen, identity)
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

    def truncate_hash(hash, seen, identity)
      truncated_hash = {}
      hash.each_with_index do |(key, val), idx|
        break if idx + 1 > @max_size

        truncated_hash[key] = if identity && identity_key?(key) && val.is_a?(String)
                                truncate_identity_string(val)
                              else
                                truncate_scoped(val, seen, identity)
                              end
      end

      truncated_hash.freeze
    end

    # Only reached when `identity` is true, i.e. under the gem-authored subtree.
    # THAT is what makes these keys identity rather than data — not the fact
    # that they are Symbols. An earlier revision floored any Symbol key called
    # `:type`/`:file`/`:function` anywhere in the notice on the theory that
    # Symbol implied gem-authored; it does not (STI `:type`, upload `:file` and
    # Sidekiq args are routinely symbol-keyed), and the measured result was that
    # a user's params inflated the notice enough to converge one rung LOWER on
    # the halving ladder and drop the very in-app frame the fingerprint needs.
    #
    # The Symbol check survives only as a cheap second narrowing: everything
    # THIS GEM puts under `errors` is symbol-keyed (`NestedException#as_json`,
    # `Backtrace.parse`), so a String key there was put there by host code
    # mutating `notice[:errors]` inside a `notify` block — supported, but not
    # this gem's identity, so treat it as data.
    #
    # No rescue is needed: `Array#include?` on a frozen Symbol array cannot
    # raise for any key type, which matters because this runs while the host
    # app is ALREADY handling an exception.
    def identity_key?(key)
      IDENTITY_KEYS.include?(key)
    end

    def truncate_identity_string(str)
      fixed_str = replace_invalid_characters(str)
      floor = [@max_size, IDENTITY_FLOOR].max
      return fixed_str if fixed_str.length <= floor

      (fixed_str.slice(0, floor) + TRUNCATED).freeze
    end

    def truncate_array(array, seen, identity)
      array
        .slice(0, @max_size)
        .map! { |elem| truncate_scoped(elem, seen, identity) }
        .freeze
    end

    def truncate_set(set, seen, identity)
      truncated_set = Set.new

      set.each do |elem|
        truncated_set << truncate_scoped(elem, seen, identity)
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
