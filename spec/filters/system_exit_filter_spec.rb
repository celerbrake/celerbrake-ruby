RSpec.describe Celerbrake::Filters::SystemExitFilter do
  subject(:system_exit_filter) { described_class.new }

  it "marks SystemExit exceptions as ignored" do
    notice = Celerbrake::Notice.new(SystemExit.new)
    expect { system_exit_filter.call(notice) }.to(
      change { notice.ignored? }.from(false).to(true),
    )
  end

  it "doesn't mark non SystemExit exceptions as ignored" do
    notice = Celerbrake::Notice.new(CelerbrakeTestError.new)
    expect(notice).not_to be_ignored
    expect { system_exit_filter.call(notice) }.not_to(change { notice.ignored? })
  end
end
