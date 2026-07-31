RSpec.describe Celerbrake::Truncator do
  def multiply_by_2_max_len(chr)
    chr * 2 * max_len
  end

  describe "#truncate" do
    subject(:truncator) { described_class.new(max_size).truncate(object) }

    let(:max_size) { 3 }
    let(:truncated) { '[Truncated]' }
    let(:max_len) { max_size + truncated.length }

    context "given a frozen string" do
      let(:object) { multiply_by_2_max_len('a') }

      it "returns a new truncated frozen string" do
        expect(truncator.length).to eq(max_len)
        expect(truncator).to be_frozen
      end
    end

    context "given a frozen hash of strings" do
      let(:object) do
        {
          banana: multiply_by_2_max_len('a'),
          kiwi: multiply_by_2_max_len('b'),
          strawberry: 'c',
          shrimp: 'd',
        }.freeze
      end

      it "returns a hash of the same size" do
        expect(truncator.size).to eq(max_size)
      end

      it "returns a frozen hash" do
        expect(truncator).to be_frozen
      end

      it "returns a hash with truncated values" do
        expect(truncator).to eq(
          banana: 'aaa[Truncated]', kiwi: 'bbb[Truncated]', strawberry: 'c',
        )
      end

      it "returns a hash with truncated strings that are frozen" do
        expect(truncator[:banana]).to be_frozen
        expect(truncator[:kiwi]).to be_frozen
      end

      it "returns a hash unfrozen untruncated strings" do
        expect(truncator[:strawberry]).not_to be_frozen
      end
    end

    context "given a frozen array of strings" do
      let(:object) do
        [
          multiply_by_2_max_len('a'),
          'b',
          multiply_by_2_max_len('c'),
          'd',
        ].freeze
      end

      it "returns an array of the same size" do
        expect(truncator.size).to eq(max_size)
      end

      it "returns a frozen array" do
        expect(truncator).to be_frozen
      end

      it "returns an array with truncated values" do
        expect(truncator).to eq(['aaa[Truncated]', 'b', 'ccc[Truncated]'])
      end

      it "returns an array with truncated strings that are frozen" do
        expect(truncator[0]).to be_frozen
        expect(truncator[2]).to be_frozen
      end

      it "returns an array with unfrozen untruncated strings" do
        expect(truncator[1]).not_to be_frozen
      end
    end

    context "given a frozen set of strings" do
      let(:object) do
        Set.new([
          multiply_by_2_max_len('a'),
          'b',
          multiply_by_2_max_len('c'),
          'd',
        ]).freeze
      end

      it "returns a set of the same size" do
        expect(truncator.size).to eq(max_size)
      end

      it "returns a frozen set" do
        expect(truncator).to be_frozen
      end

      it "returns a set with truncated values" do
        expect(truncator).to eq(Set.new(['aaa[Truncated]', 'b', 'ccc[Truncated]']))
      end
    end

    context "given an arbitrary frozen object that responds to #to_json" do
      let(:object) do
        obj = Object.new
        def obj.to_json
          '{"object":"shrimp"}'
        end
        obj.freeze
      end

      it "returns a string of a max len size" do
        expect(truncator.length).to eq(max_len)
      end

      it "returns a frozen object" do
        expect(truncator).to be_frozen
      end

      it "converts the object to truncated JSON" do
        expect(truncator).to eq('{"o[Truncated]')
      end
    end

    context "given an arbitrary object that doesn't respond to #to_json" do
      let(:object) do
        obj = Object.new
        allow(obj).to receive(:to_json)
          .and_raise(Celerbrake::Notice::JSON_EXCEPTIONS.first)
        obj
      end

      it "converts the object to a truncated string" do
        expect(truncator.length).to eq(max_len)
        expect(truncator).to eq('#<O[Truncated]')
      end
    end

    shared_examples 'self returning objects' do |object|
      it "returns the passed object" do
        expect(described_class.new(max_size).truncate(object)).to eql(object)
      end
    end

    [1, true, false, :symbol, nil].each do |object|
      include_examples 'self returning objects', object
    end

    context "given a recursive array" do
      let(:object) do
        a = %w[aaaaa bb]
        a << a
        a << 'c'
        a
      end

      it "prevents recursion" do
        expect(truncator).to eq(['aaa[Truncated]', 'bb', '[Circular]'])
      end
    end

    context "given a recursive array with recursive hashes" do
      let(:object) do
        a = []
        a << a

        h = {}
        h[:k] = h
        a << h << 'aaaa'
      end

      it "prevents recursion" do
        expect(truncator).to eq(['[Circular]', { k: '[Circular]' }, 'aaa[Truncated]'])
        expect(truncator).to be_frozen
      end
    end

    context "given a recursive set with recursive arrays" do
      let(:object) do
        s = Set.new
        s << s

        h = {}
        h[:k] = h
        s << h << 'aaaa'
      end

      it "prevents recursion" do
        expect(truncator).to eq(
          Set.new(['[Circular]', { k: '[Circular]' }, 'aaa[Truncated]']),
        )
        expect(truncator).to be_frozen
      end
    end

    context "given a hash with long strings" do
      let(:object) do
        {
          a: multiply_by_2_max_len('a'),
          b: multiply_by_2_max_len('b'),
          c: { d: multiply_by_2_max_len('d'), e: 'e' },
        }
      end

      it "truncates the long strings" do
        expect(truncator).to eq(
          a: 'aaa[Truncated]', b: 'bbb[Truncated]', c: { d: 'ddd[Truncated]', e: 'e' },
        )
        expect(truncator).to be_frozen
      end
    end

    context "given a string with valid unicode characters" do
      let(:object) { "€€€€€" }

      it "truncates the string" do
        expect(truncator).to eq("€€€[Truncated]")
      end
    end

    context "given an ASCII-8BIT string with invalid characters" do
      let(:object) do
        # Shenanigans to get a bad ASCII-8BIT string. Direct conversion raises error.
        encoded = Base64.encode64("\xD3\xE6\xBC\x9D\xBA").encode!('ASCII-8BIT')
        Base64.decode64(encoded).freeze
      end

      it "converts and truncates the string to UTF-8" do
        expect(truncator).to eq("���[Truncated]")
        expect(truncator).to be_frozen
      end
    end

    context "given an array with hashes and hash-like objects with identical keys" do
      let(:hashie) { Class.new(Hash) }

      let(:object) do
        {
          errors: [
            { file: 'a' },
            { file: 'a' },
            hashie.new.merge(file: 'bcde'),
          ],
        }
      end

      it "truncates values" do
        expect(truncator).to eq(
          errors: [
            { file: 'a' },
            { file: 'a' },
            hashie.new.merge(file: 'bcd[Truncated]'),
          ],
        )
        expect(truncator).to be_frozen
      end
    end

    # Identity keys carry WHICH BUG this is, not how much detail we kept.
    # Cutting them makes the server fingerprint a payload-size artifact as a
    # brand-new error group, which fires an alert and opens a triage task.
    #
    # The floor applies ONLY where the caller says the subtree is gem-authored.
    # `Notice#truncate` says so for `:errors` and for nothing else.
    context "given the identity keys of an error" do
      let(:max_size) { 4 }
      let(:floored)  { Celerbrake::Truncator::IDENTITY_FLOOR }
      let(:cut_mark) { Celerbrake::Truncator::TRUNCATED }

      let(:klass) { 'ActiveRecord::DatabaseConnectionError' }
      let(:path)  { '/GEM_ROOT/gems/activerecord-8.1.3/lib/active_record/x.rb' }

      let(:errors) do
        [{ type: klass,
           message: 'm' * 50,
           backtrace: [{ file: path, line: 42, function: 'connect' }] }]
      end

      def truncate_identity(obj)
        described_class.new(max_size).truncate_identity_subtree(obj)
      end

      def truncate_payload(obj)
        described_class.new(max_size).truncate(obj)
      end

      context "when the caller marks the subtree as gem-authored" do
        it "keeps type, file and function whole at a budget that would shred them" do
          error = truncate_identity(errors)[0]

          expect(error[:type]).to eq(klass)
          expect(error[:backtrace][0][:file]).to eq(path)
          expect(error[:backtrace][0][:function]).to eq('connect')
        end

        it "still truncates everything that is not an identity key" do
          expect(truncate_identity(errors)[0][:message]).to eq("#{'m' * 4}#{cut_mark}")
        end

        it "floors identity keys rather than exempting them, so they stay bounded" do
          huge = truncate_identity([{ type: 'Z' * 100_000 }])[0][:type]

          expect(huge.length).to eq(floored + cut_mark.length)
        end

        it "does not raise on identity values that are not strings" do
          [nil, 42, :sym, [1, 2], { a: 1 }, Object.new].each do |value|
            expect { truncate_identity([{ type: value, file: value, function: value }]) }
              .not_to raise_error
          end
        end

        it "treats a String key inside the subtree as data, not identity" do
          out = truncate_identity([{ 'file' => 'bcdefgh', 'type' => 'wxyzabc' }])[0]

          expect(out['file']).to eq("bcde#{cut_mark}")
          expect(out['type']).to eq("wxyz#{cut_mark}")
        end
      end

      # THE REGRESSION. A first cut of this change matched IDENTITY_KEYS by name
      # anywhere in the notice, on the theory that a Symbol key implied the gem
      # had written it. Applications symbol-key their own params all the time
      # (STI `:type`, uploads `:file`, Sidekiq args), so the floor inflated user
      # data 5x, which pushed the notice a rung lower on the halving ladder,
      # which dropped MORE backtrace frames — losing the in-app frame the server
      # fingerprints on. The floor caused the defect it exists to prevent.
      context "when the caller does not mark the subtree" do
        it "truncates a symbol-keyed params[:file] at max_size, not at the floor" do
          out = truncate_payload(file: 'F' * 400, type: 'T' * 400, function: 'U' * 400)

          expect(out[:file]).to eq("#{'F' * max_size}#{cut_mark}")
          expect(out[:type]).to eq("#{'T' * max_size}#{cut_mark}")
          expect(out[:function]).to eq("#{'U' * max_size}#{cut_mark}")
        end

        it "truncates identity-named keys exactly like any other key" do
          out = truncate_payload(file: 'F' * 400, other: 'O' * 400)

          expect(out[:file].length).to eq(out[:other].length)
        end

        it "is what the unmarked call means all the way down a nested payload" do
          out = truncate_payload(rows: [{ type: 'T' * 400 }])

          expect(out[:rows][0][:type]).to eq("#{'T' * max_size}#{cut_mark}")
        end
      end

      # THE SIGNATURE REGRESSION. The scope was first carried by a keyword
      # (`truncate(object, seen = Set.new, identity: false)`), which silently
      # broke every caller that passes a bare symbol-keyed Hash: Ruby parses
      # the literal as KEYWORDS the moment the method declares any, so
      # `truncate(rows: [1])` raised `ArgumentError: wrong number of arguments
      # (given 0, expected 1..2)`. That shape is used throughout this file and
      # in the repro recorded in the branch's own commit messages; on the Ruby
      # 2.5-2.7 the gemspec still supports, a symbol-keyed Hash VARIABLE
      # converts too. The scope now travels as a second method name, so
      # `#truncate`'s arity is byte-identical to every released version.
      context "when a caller passes a bare symbol-keyed hash" do
        it "treats it as the object to truncate, not as keyword arguments" do
          expect(described_class.new(39).truncate(rows: [1])).to eq(rows: [1])
        end

        it "treats it as the object on the identity-scoped entry point too" do
          expect(described_class.new(39).truncate_identity_subtree(rows: [1]))
            .to eq(rows: [1])
        end

        it "accepts a symbol-keyed hash held in a variable" do
          payload = { type: 'T' * 400, other: 'O' * 400 }

          out = described_class.new(39).truncate(payload)

          expect(out[:type]).to eq("#{'T' * 39}#{cut_mark}")
          expect(out[:other]).to eq("#{'O' * 39}#{cut_mark}")
        end
      end
    end

    # Frame retention. The identity floor stops the ladder from CUTTING the
    # strings the fingerprint reads; this stops it from DROPPING the frame
    # they live on. The server keys on its top app frame (`frames.find {
    # in_app? } || frames.first`), which sits at ordinal 49-53 on the real
    # production payloads, so a plain slice below ~78 deletes it and the key
    # becomes a function of the payload's size. When slicing a gem-authored
    # backtrace would drop the FIRST in-app frame, it is kept as the slice's
    # last element instead — same element count, same relative order (its
    # ordinal exceeds every kept frame's), and the frame it displaces is
    # provably not the fingerprint's (neither in-app nor frames.first).
    context "given a backtrace inside the gem-authored subtree" do
      let(:app_frame) do
        { file: '/PROJECT_ROOT/app/controllers/api/v3/base_controller.rb',
          line: 13, function: 'db_check' }
      end

      def gem_frame(i)
        { file: "/GEM_ROOT/gems/activerecord-8.1.3/lib/active_record/f#{i}.rb",
          line: i, function: "m#{i}" }
      end

      def frames_with_app_at(index, total = 100)
        frames = Array.new(total) { |i| gem_frame(i) }
        frames[index] = app_frame
        frames
      end

      def sliced_backtrace(budget, frames)
        described_class.new(budget)
                       .truncate_identity_subtree([{ type: 'T', backtrace: frames }])[0][:backtrace]
      end

      # THE REGRESSION, at the exact rungs that minted production groups
      # 70/68/67/71 (39/19/9/4 frames, 0 of 623 sampled occurrences with an
      # in-app frame, against 1377/1377 in the uncut group 69).
      it "keeps the first in-app frame when the slice would drop it" do
        [39, 19, 9, 4].each do |budget|
          out = sliced_backtrace(budget, frames_with_app_at(52))

          expect(out.size).to eq(budget)
          expect(out.last[:file]).to eq(app_frame[:file])
          expect(out[0...-1]).to eq(out[0...-1].sort_by { |f| f[:line] })
        end
      end

      it "keeps the FIRST in-app frame — the one the server fingerprints on" do
        frames = frames_with_app_at(52)
        frames[60] = { file: '/PROJECT_ROOT/app/models/later.rb',
                       line: 1, function: 'other' }

        out = sliced_backtrace(39, frames)

        expect(out.last[:file]).to eq(app_frame[:file])
      end

      it "applies the identity floor to the retained frame like any other" do
        frames = frames_with_app_at(52)
        frames[52] = { file: "/PROJECT_ROOT/#{'p' * 400}.rb", line: 1, function: 'f' }

        out = sliced_backtrace(4, frames)

        expect(out.last[:file].length)
          .to eq(Celerbrake::Truncator::IDENTITY_FLOOR +
                 Celerbrake::Truncator::TRUNCATED.length)
      end

      # The server's fallback rule for paths its placeholders never rewrote:
      # anything not matching %r{/(gems|vendor)/} is an app frame. A host
      # whose RootDirectoryFilter was removed still fingerprints on that.
      it "treats a bare un-rewritten application path as in-app, as the server does" do
        frames = frames_with_app_at(52)
        frames[52] = { file: '/home/deploy/apps/shop/app/models/order.rb',
                       line: 7, function: 'total' }

        out = sliced_backtrace(19, frames)

        expect(out.last[:file]).to eq('/home/deploy/apps/shop/app/models/order.rb')
      end

      # CONTROLS — behaviour that must be byte-identical to the unfixed gem.
      it "is the plain slice when the in-app frame already survives" do
        out = sliced_backtrace(78, frames_with_app_at(52))

        expect(out.size).to eq(78)
        expect(out.last[:file]).to eq(gem_frame(77)[:file])
      end

      it "is the plain slice when no frame is in-app" do
        frames = Array.new(100) { |i| gem_frame(i) }
        frames[52] = { file: '/app/vendor/bundle/ruby/3.4.0/gems/x/lib/y.rb',
                       line: 1, function: 'z' }
        frames[53] = { file: '   ', line: 1, function: 'blank' }

        out = sliced_backtrace(39, frames)

        expect(out.last[:file]).to eq(gem_frame(38)[:file])
      end

      it "leaves a :backtrace in an unmarked (host) payload alone" do
        out = described_class.new(39)
                             .truncate(rows: [{ backtrace: frames_with_app_at(52) }])

        bt = out[:rows][0][:backtrace]
        expect(bt.size).to eq(39)
        # No retention: the app frame at index 52 is simply gone, and the last
        # element is the 39th frame (strings cut at the budget — no floor
        # in host data either, which "given the identity keys" already pins).
        expect(bt.last[:file]).to start_with('/GEM_ROOT/')
        expect(bt.map { |f| f[:file] }).not_to include(app_frame[:file])
      end

      it "leaves a String-keyed 'backtrace' alone — host data, not identity" do
        out = described_class.new(39)
                             .truncate_identity_subtree([{ 'backtrace' => frames_with_app_at(52) }])

        expect(out[0]['backtrace'].last[:file]).to eq(gem_frame(38)[:file])
      end

      it "reads a String 'file' key off a frame, as the server's parser does" do
        frames = frames_with_app_at(52)
        frames[52] = { 'file' => '/PROJECT_ROOT/app/models/order.rb' }

        out = sliced_backtrace(19, frames)

        # Retention reads the String key (the server does); the floor still
        # does not — a String-keyed value is host data and cuts at the budget.
        expect(out.last['file']).to start_with('/PROJECT_ROOT/')
      end

      it "does not raise on frames of any shape, and declines them all" do
        odd = [nil, 42, :sym, [1], Object.new,
               'app/models/order.rb:12:in `total\'',
               { file: nil }, { file: 12 }, { line: 3 },
               { file: (+"/PROJECT\xff_ROOT/x.rb").force_encoding('UTF-8') },
               { file: '/x.rb'.encode('UTF-16LE') }]
        frames = Array.new(100) { |i| gem_frame(i) }
        odd.each_with_index { |f, i| frames[40 + i] = f }

        out = nil
        expect { out = sliced_backtrace(9, frames) }.not_to raise_error
        expect(out.size).to eq(9)
        expect(out.last[:file]).to eq(gem_frame(8)[:file])
      end

      it "still reports a backtrace array that appears twice as circular" do
        frames = frames_with_app_at(52)
        errors = [{ type: 'A', backtrace: frames }, { type: 'B', backtrace: frames }]

        out = described_class.new(39).truncate_identity_subtree(errors)

        expect(out[1][:backtrace]).to eq(Celerbrake::Truncator::CIRCULAR)
      end
    end

    # The identity floor buys fingerprint stability with delivery headroom:
    # `Notice#context` is built once in `#initialize` and is absent from
    # TRUNCATABLE_KEYS, so a notice made almost entirely of `rootDirectory` /
    # `versions` / `error_message` can exhaust the ladder and be dropped. The
    # floor makes that happen marginally earlier than the unfloored gem.
    #
    # That band is ACCEPTED, not closed — the only remedy (a final unfloored
    # pass before giving up) would ship a `Ex[Truncated]` fingerprint, i.e.
    # fabricate the very error group the floor exists to prevent. But it must
    # stay BOUNDED, so this pins the bound.
    #
    # The instrument needs no second checkout: stubbing IDENTITY_FLOOR to 0
    # makes `#truncate_identity_string` compute `[@max_size, 0].max`, which is
    # `#truncate_string` exactly — the unfloored gem, in process.
    describe "the delivery headroom the identity floor costs" do
      # `Notice#to_json` measures the payload BEFORE each pass, so the last
      # state it ever sees is the one cut at budget 2: `errors` sliced to 2
      # entries, each keeping its first 2 keys (`type`, `message`). At most
      # TWO floored strings can therefore exist at the deciding moment.
      #
      # Captured eagerly, because the examples below stub IDENTITY_FLOOR to 0
      # and a lazy `let` would read the stub instead of the real ceiling.
      let!(:max_band) { 2 * (Celerbrake::Truncator::IDENTITY_FLOOR - 2) }

      # A fresh Config logs to File::NULL, which matters: every probe that
      # lands past the cliff makes `Notice#truncate` log the whole payload.
      around do |example|
        previous = Celerbrake::Config.instance
        Celerbrake::Config.instance = Celerbrake::Config.new
        example.run
      ensure
        Celerbrake::Config.instance = previous
      end

      # Two nested exceptions whose class names sit past the floor: the worst
      # case the bound has to cover, since `errors` keeps two entries.
      def caused_exception(class_name_length)
        named = lambda do |i|
          name = "E#{i}#{'x' * (class_name_length - 2)}"
          Class.new(RuntimeError) { define_singleton_method(:name) { name } }
        end

        begin
          begin
            raise named[0], 'inner'
          rescue StandardError
            raise named[1], 'outer'
          end
        rescue StandardError => e
          e
        end
      end

      def largest_root_that_delivers(class_name_length)
        delivers = lambda do |len|
          Celerbrake::Config.instance.root_directory = 'r' * len
          !Celerbrake::Notice.new(caused_exception(class_name_length)).to_json.nil?
        end

        lo = 0
        hi = Celerbrake::Notice::MAX_NOTICE_SIZE
        raise 'instrument broken: an empty root must deliver' unless delivers[lo]
        raise 'instrument broken: a full-size root must drop' if delivers[hi]

        while hi - lo > 1
          mid = (lo + hi) / 2
          delivers[mid] ? lo = mid : hi = mid
        end
        lo
      end

      def unfloored_largest_root_that_delivers(class_name_length)
        stub_const('Celerbrake::Truncator::IDENTITY_FLOOR', 0)
        largest_root_that_delivers(class_name_length)
      end

      it "is bounded by two floored identity strings, whatever the class name" do
        floored = largest_root_that_delivers(400)
        band = unfloored_largest_root_that_delivers(400) - floored

        expect(band).to be_positive    # the cost is real, not hypothetical
        expect(band).to be <= max_band # ...and 508 bytes is the ceiling
      end

      it "is negligible at the exception class lengths production actually has" do
        # Longest exception class observed across 148 production error groups
        # was 48 characters — far under the floor, so the floor never cuts and
        # the band is a rounding error on a 64 KB notice.
        floored = largest_root_that_delivers(48)
        band = unfloored_largest_root_that_delivers(48) - floored

        expect(band).to be < max_band / 4
      end
    end
  end
end
