RSpec.describe Celerbrake::Filters::DependencyFilter do
  subject(:dependency_filter) { described_class.new }

  let(:notice) { Celerbrake::Notice.new(CelerbrakeTestError.new) }

  describe "#call" do
    it "attaches loaded dependencies to context/versions/dependencies" do
      dependency_filter.call(notice)
      expect(notice[:context][:versions][:dependencies]).to include(
        'celerbrake-ruby' => Celerbrake::CELERBRAKE_RUBY_VERSION,
      )
    end
  end
end
