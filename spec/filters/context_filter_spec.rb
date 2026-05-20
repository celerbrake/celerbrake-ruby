RSpec.describe Celerbrake::Filters::ContextFilter do
  let(:notice) { Celerbrake::Notice.new(CelerbrakeTestError.new) }

  context "when the current context is empty" do
    it "doesn't merge anything with params" do
      described_class.new.call(notice)
      expect(notice[:params]).to be_empty
    end
  end

  context "when the current context has some data" do
    it "merges the data with params" do
      Celerbrake.merge_context(apples: 'oranges')
      described_class.new.call(notice)
      expect(notice[:params]).to eq(celerbrake_context: { apples: 'oranges' })
    end

    it "clears the data from the current context" do
      context = { apples: 'oranges' }
      Celerbrake.merge_context(context)
      described_class.new.call(notice)
      expect(Celerbrake::Context.current).to be_empty
    end

    it "does not mutate the provided context object" do
      context = { apples: 'oranges' }
      Celerbrake.merge_context(context)
      described_class.new.call(notice)
      expect(context).to match(apples: 'oranges')
    end
  end
end
