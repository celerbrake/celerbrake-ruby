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
        described_class.new(max_size).truncate(obj, identity: true)
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

        it "is what `identity: false` means all the way down a nested payload" do
          out = truncate_payload(rows: [{ type: 'T' * 400 }])

          expect(out[:rows][0][:type]).to eq("#{'T' * max_size}#{cut_mark}")
        end
      end
    end
  end
end
