RSpec.describe Celerbrake::Filters::ExceptionAttributesFilter do
  subject(:exception_attributes_filter) { described_class.new }

  describe "#call" do
    let(:notice) { Celerbrake::Notice.new(ex) }

    context "when #to_celerbrake returns a non-Hash object" do
      let(:ex) do
        Class.new(CelerbrakeTestError) do
          def to_celerbrake
            Object.new
          end
        end.new
      end

      it "doesn't raise" do
        expect { exception_attributes_filter.call(notice) }.not_to raise_error
        expect(notice[:params]).to be_empty
      end
    end

    context "when #to_celerbrake errors out" do
      let(:ex) do
        Class.new(CelerbrakeTestError) do
          def to_celerbrake
            1 / 0
          end
        end.new
      end

      it "doesn't raise" do
        expect { exception_attributes_filter.call(notice) }.not_to raise_error
        expect(notice[:params]).to be_empty
      end
    end

    context "when #to_celerbrake returns a hash" do
      let(:ex) do
        Class.new(CelerbrakeTestError) do
          def to_celerbrake
            { params: { foo: '1' } }
          end
        end.new
      end

      it "merges parameters with the notice" do
        exception_attributes_filter.call(notice)
        expect(notice[:params]).to eq(foo: '1')
      end
    end
  end
end
