RSpec.describe Celerbrake::Notice do
  let(:notice) { described_class.new(CelerbrakeTestError.new, bingo: '1') }

  describe "#to_json" do
    context "app_version" do
      context "when missing" do
        before { Celerbrake::Config.instance.merge(app_version: nil) }

        it "doesn't include app_version" do
          expect(notice.to_json).not_to match(/"context":{"version":"1.2.3"/)
        end
      end

      context "when present" do
        let(:notice) { described_class.new(CelerbrakeTestError.new) }

        before do
          Celerbrake::Config.instance.merge(
            app_version: "1.2.3",
            root_directory: "/one/two",
          )
        end

        it "includes app_version" do
          expect(notice.to_json).to match(/"context":{"version":"1.2.3"/)
        end

        it "includes root_directory" do
          expect(notice.to_json).to match(%r{"rootDirectory":"/one/two"})
        end
      end
    end

    context "when versions is empty" do
      it "doesn't set the 'versions' payload" do
        expect(notice.to_json).not_to match(
          /"context":{"versions":{"dep":"1.2.3"}}/,
        )
      end
    end

    context "when versions is not empty" do
      it "sets the 'versions' payload" do
        notice[:context][:versions] = { 'dep' => '1.2.3' }
        expect(notice.to_json).to match(
          /"context":{.*"versions":{"dep":"1.2.3"}.*}/,
        )
      end
    end

    context "truncation" do
      it "truncates context/error_message" do
        msg = 'message-' * 64000
        notice = described_class.new(StandardError.new(msg))
        expect(notice[:context][:error_message]).to(include('message-[Truncated]'))
        expect(notice[:context][:error_message].length).to be < msg.length
      end

      shared_examples 'payloads' do |size, msg|
        it msg do
          ex = CelerbrakeTestError.new

          backtrace = []
          size.times { backtrace << "bin/rails:3:in `<main>'" }
          ex.set_backtrace(backtrace)

          notice = described_class.new(ex)

          expect(notice.to_json.bytesize).to be < 64000
        end
      end

      max_msg = 'truncates to the max allowed size'

      context "with an extremely huge payload" do
        include_examples 'payloads', 200_000, max_msg
      end

      context "with a big payload" do
        include_examples 'payloads', 50_000, max_msg
      end

      small_msg = "doesn't truncate it"

      context "with a small payload" do
        include_examples 'payloads', 1000, small_msg
      end

      context "with a tiny payload" do
        include_examples 'payloads', 300, small_msg
      end

      # The identity floor and its scope. `Notice#truncate` walks
      # TRUNCATABLE_KEYS and marks exactly ONE of them — IDENTITY_SUBTREE
      # (`errors`) — as gem-authored, so `type`/`file`/`function` are floored
      # there and NOWHERE else. Both halves are load-bearing:
      #
      #   * without the floor, the halving ladder cuts the exception class and
      #     the surviving frame's path at a point that depends on how big the
      #     payload happened to be, and the server keys a brand-new error group
      #     off that cut — one `error_group.new` alert and one autonomous triage
      #     task per size band;
      #   * without the SCOPE, an application's own symbol-keyed `:type`/`:file`
      #     params get floored too, inflating the notice, converging one rung
      #     lower and dropping MORE backtrace frames than the unfixed gem —
      #     including the in-app frame the fingerprint reads.
      context "identity" do
        # 100 gem frames with ONE app frame at index 50: retained at the ladder's
        # 78-frame rung, deleted at the 39-frame rung below it. That is the
        # difference this spec is built to detect.
        def exception_with_app_frame
          gem_frame = lambda { |i|
            "/GEM_ROOT/gems/activerecord-8.1.3/lib/active_record/" \
              "connection_adapters/abstract/connection_pool.rb:#{100 + i}:in `checkout'"
          }
          frames = Array.new(100) { |i| gem_frame.call(i) }
          frames[50] = "/PROJECT_ROOT/app/lib/services/billing/renewal.rb:88:in `charge!'"

          ex = CelerbrakeTestError.new
          ex.set_backtrace(frames)
          ex
        end

        def delivered(params)
          json = described_class.new(exception_with_app_frame, params).to_json
          expect(json).not_to be_nil
          JSON.parse(json)
        end

        # n rows fat enough to force the notice several rungs down the ladder.
        def rows(n, key_a, key_b, key_c)
          Array.new(n) do |i|
            { key_a => "data:application/pdf;base64,#{'A' * 380}#{i}",
              key_b => "Billing::Import::Row::#{'V' * 380}#{i}",
              key_c => "handler_#{'h' * 380}#{i}" }
          end
        end

        def app_frame(payload)
          payload['errors'][0]['backtrace']
            .find { |f| f['file'].to_s.start_with?('/PROJECT_ROOT') }
        end

        # NESTED params, because nesting is what actually drives a notice to the
        # bottom of the ladder: at budget b a depth-4 hash costs ~b**4, so this
        # one is still ~400 KB at b=10 and only fits at b=4 — the same rung
        # production groups 67/68/71 were cut at. A single flat 200 KB string
        # would settle around b=2500 and prove nothing.
        def deeply_nested_params(depth = 4, breadth = 10)
          return 'v' * 20 if depth.zero?

          (0...breadth).each_with_object({}) do |i, h|
            h[:"k#{i}"] = deeply_nested_params(depth - 1, breadth)
          end
        end

        it "keeps the exception class whole however far the ladder descends" do
          payload = delivered(deeply_nested_params)

          # Guard the instrument: this payload must actually reach the bottom.
          expect(payload['errors'][0]['backtrace'].size).to be <= 4
          expect(payload['errors'][0]['type']).to eq('CelerbrakeTestError')
        end

        it "keeps the surviving frame's file and function whole" do
          frame = delivered(deeply_nested_params)['errors'][0]['backtrace'][0]

          expect(frame['file']).not_to include(Celerbrake::Truncator::TRUNCATED)
          expect(frame['function']).to eq('checkout')
        end

        # THE REGRESSION SPEC. Same payload twice; only the params' KEY NAMES
        # differ. If the floor escapes `errors`, the left-hand run inflates and
        # loses frames the right-hand run keeps.
        it "does not let identity-named user params cost backtrace frames" do
          colliding = delivered(rows: rows(90, :file, :type, :function))
          control   = delivered(rows: rows(90, :filex, :typex, :functionx))

          expect(colliding['errors'][0]['backtrace'].size)
            .to eq(control['errors'][0]['backtrace'].size)
          expect(app_frame(colliding)).not_to be_nil
        end

        it "truncates a symbol-keyed params[:file] at the notice's budget" do
          payload = delivered(rows: rows(90, :file, :type, :function))
          value = payload['params']['rows'][0]['file']

          expect(value).to include(Celerbrake::Truncator::TRUNCATED)
          expect(value.length).to be < Celerbrake::Truncator::IDENTITY_FLOOR
        end

        # IDENTITY_SUBTREE is a CONVENTION, not an enforced boundary, and the
        # code must not be documented as if it were one. `errors` is missing
        # from WRITABLE_KEYS, but only `#[]=` consults that list — `#[]` hands
        # back the live object, and mutating it inside a `notify` block is the
        # documented public way to adjust a notice. The sibling `celerbrake`
        # gem's Logger integration relies on precisely this to drop internal
        # Logger frames:
        #
        #   notice[:errors].first[:backtrace] =
        #     backtrace.drop_while { |frame| frame[:file] =~ %r{/logger.rb\z} }
        #
        # These two examples pin both halves of that reality, so neither the
        # comment nor the sibling gem can silently go stale.
        context "when host code reaches into the identity subtree" do
          it "is not prevented from doing so, which the sibling gem depends on" do
            notice = described_class.new(exception_with_app_frame)

            expect { notice[:errors].first[:backtrace] = [] }.not_to raise_error
            expect(notice[:errors].first[:backtrace]).to eq([])
          end

          it "inherits the identity floor for whatever it leaves behind" do
            # Params fat enough to drive the ladder to the bottom, so the
            # host-written frame is actually put through the truncator.
            notice = described_class.new(exception_with_app_frame, deeply_nested_params)
            notice[:errors].first[:backtrace] =
              [{ file: 'H' * 400, line: 1, function: 'x' }]

            frame = JSON.parse(notice.to_json)['errors'][0]['backtrace'][0]

            expect(frame['file'].length)
              .to eq(Celerbrake::Truncator::IDENTITY_FLOOR +
                     Celerbrake::Truncator::TRUNCATED.length)
          end
        end
      end

      context "when truncation failed" do
        it "returns nil" do
          allow_any_instance_of(Celerbrake::Truncator)
            .to receive(:reduce_max_size).and_return(0)

          encoded = Base64.encode64("\xD3\xE6\xBC\x9D\xBA").encode!('ASCII-8BIT')
          bad_string = Base64.decode64(encoded)

          ex = CelerbrakeTestError.new

          backtrace = []
          10.times { backtrace << "bin/rails:3:in `<#{bad_string}>'" }
          ex.set_backtrace(backtrace)

          notice = described_class.new(ex)
          expect(notice.to_json).to be_nil
        end
      end

      describe "object replacement with its string version" do
        subject(:json) { notice.to_json }

        let(:klass) { Class.new }
        let(:ex) { CelerbrakeTestError.new }
        let(:params) { { bingo: [Object.new, klass.new] } }
        let(:notice) { described_class.new(ex, params) }

        before do
          backtrace = []
          backtrace_size.times { backtrace << "bin/rails:3:in `<main>'" }
          ex.set_backtrace(backtrace)
        end

        context "with payload within the limits" do
          let(:backtrace_size) { 1000 }

          it "doesn't happen" do
            expect(json).to match(/bingo":\["#<Object:.+>","#<#<Class:.+>:.+>"/)
          end
        end

        context "with payload bigger than the limit" do
          let(:backtrace_size) { 50_000 }

          it "happens" do
            expect(json).to match(/bingo":\[".+Object.+",".+Class.+"/)
          end
        end
      end
    end

    context "given a closed IO object" do
      context "and when it is not monkey-patched by ActiveSupport" do
        it "is not getting truncated" do
          notice[:params] = { obj: IO.new(0).tap(&:close) }
          expect(notice.to_json).to match(/"obj":"#<IO:0x.+>"/)
        end
      end

      context "and when it is monkey-patched by ActiveSupport" do
        # Instances of this class contain a closed IO object assigned to an
        # instance variable. Normally, the JSON gem, which we depend on can
        # parse closed IO objects. However, because ActiveSupport monkey-patches
        # #to_json and calls #to_a on them, they raise IOError when we try to
        # serialize them.
        #
        # @see https://goo.gl/0A3xNC
        # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
        class ObjectWithIoIvars
          def initialize
            @bongo = Tempfile.new('bongo').tap(&:close)
          end

          # @raise [NotImplementedError] when inside a Rails environment
          def to_json(*)
            raise NotImplementedError
          end
        end
        # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration

        # @see ObjectWithIoIvars
        # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
        class ObjectWithNestedIoIvars
          def initialize
            @bish = ObjectWithIoIvars.new
          end

          # @see ObjectWithIoIvars#to_json
          def to_json(*)
            raise NotImplementedError
          end
        end
        # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration

        context "and also when it's a closed Tempfile" do
          it "doesn't fail" do
            notice[:params] = { obj: Tempfile.new('bongo').tap(&:close) }
            expect(notice.to_json).to match(/"obj":"#<(Temp)?file:0x.+>"/i)
          end
        end

        context "and also when it's an IO ivar" do
          it "doesn't fail" do
            notice[:params] = { obj: ObjectWithIoIvars.new }
            expect(notice.to_json).to match(/"obj":".+ObjectWithIoIvars.+"/)
          end

          context "and when it's deeply nested inside a hash" do
            it "doesn't fail" do
              notice[:params] = { a: { b: { c: ObjectWithIoIvars.new } } }
              expect(notice.to_json).to match(
                /"params":{"a":{"b":{"c":".+ObjectWithIoIvars.+"}}.*}/,
              )
            end
          end

          context "and when it's deeply nested inside an array" do
            it "doesn't fail" do
              notice[:params] = { a: [[ObjectWithIoIvars.new]] }
              expect(notice.to_json).to match(
                /"params":{"a":\[\[".+ObjectWithIoIvars.+"\]\].*}/,
              )
            end
          end
        end

        context "and also when it's a non-IO ivar, which contains an IO ivar itself" do
          it "doesn't fail" do
            notice[:params] = { obj: ObjectWithNestedIoIvars.new }
            expect(notice.to_json).to match(/"obj":".+ObjectWithNested.+"/)
          end
        end
      end
    end

    it "overwrites the 'notifier' payload with the default values" do
      notice[:notifier] = { name: 'bingo', bango: 'bongo' }

      expect(notice.to_json)
        .to match(/"notifier":{"name":"celerbrake-ruby","version":".+","url":".+"}/)
    end

    it "always contains context/hostname" do
      expect(notice.to_json)
        .to match(/"context":{.*"hostname":".+".*}/)
    end

    it "defaults to the error severity" do
      expect(notice.to_json).to match(/"context":{.*"severity":"error".*}/)
    end

    it "always contains environment/program_name" do
      expect(notice.to_json)
        .to match(%r|"environment":{"program_name":.+/rspec.*|)
    end

    it "contains errors" do
      expect(notice.to_json)
        .to match(/"errors":\[{"type":"CelerbrakeTestError","message":"App crash/)
    end

    it "contains a backtrace" do
      expect(notice.to_json)
        .to match(%r|"backtrace":\[{"file":"/home/.+/spec/spec_helper.rb"|)
    end

    it "contains params" do
      expect(notice.to_json).to match(/"params":{"bingo":"1"}/)
    end
  end

  describe "#[]" do
    it "accesses payload" do
      expect(notice[:params]).to eq(bingo: '1')
    end

    it "raises error if notice is ignored" do
      notice.ignore!
      expect { notice[:params] }
        .to raise_error(Celerbrake::Error, 'cannot access ignored Celerbrake::Notice')
    end
  end

  describe "#[]=" do
    it "sets a payload value" do
      hash = { bingo: 'bango' }
      notice[:params] = hash
      expect(notice[:params]).to eq(hash)
    end

    it "raises error if notice is ignored" do
      notice.ignore!
      expect { notice[:params] = {} }
        .to raise_error(Celerbrake::Error, 'cannot access ignored Celerbrake::Notice')
    end

    it "raises error when trying to assign unrecognized key" do
      expect { notice[:bingo] = 1 }
        .to raise_error(Celerbrake::Error, /:bingo is not recognized among/)
    end

    it "raises when setting non-hash objects as the value" do
      expect { notice[:params] = Object.new }
        .to raise_error(Celerbrake::Error, 'Got Object value, wanted a Hash')
    end
  end

  describe "#stash" do
    subject { described_class.new(CelerbrakeTestError.new) }

    it { is_expected.to respond_to(:stash) }
  end
end
