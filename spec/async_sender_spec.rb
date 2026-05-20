RSpec.describe Celerbrake::AsyncSender do
  let(:endpoint) { 'https://api.celerbrake.com/api/v3/projects/1/notices' }
  let(:queue_size) { 10 }
  let(:notice) { Celerbrake::Notice.new(CelerbrakeTestError.new) }

  before do
    stub_request(:post, endpoint).to_return(status: 201, body: '{}')
    Celerbrake::Config.instance = Celerbrake::Config.new(
      project_id: '1',
      workers: 3,
      queue_size: 10,
    )
  end

  describe "#send" do
    subject(:async_sender) { described_class.new }

    context "when sender has the capacity to send" do
      it "sends notices to Celerbrake" do
        2.times { async_sender.send(notice, Celerbrake::Promise.new) }
        async_sender.close

        expect(a_request(:post, endpoint)).to have_been_made.twice
      end

      it "returns a resolved promise" do
        promise = Celerbrake::Promise.new
        async_sender.send(notice, promise)
        async_sender.close

        expect(promise).to be_resolved
      end
    end

    context "when sender has exceeded the capacity to send" do
      before do
        Celerbrake::Config.instance = Celerbrake::Config.new(
          project_id: '1',
          workers: 0,
          queue_size: 1,
        )
      end

      it "doesn't send the exceeded notices to Celerbrake" do
        15.times { async_sender.send(notice, Celerbrake::Promise.new) }
        async_sender.close

        expect(a_request(:post, endpoint)).not_to have_been_made
      end

      it "returns a rejected promise" do
        promise = nil
        15.times do
          promise = async_sender.send(notice, Celerbrake::Promise.new)
        end
        async_sender.close

        expect(promise).to be_rejected
        expect(promise.value).to eq(
          'error' => "AsyncSender has reached its capacity of 1",
        )
      end
    end
  end
end
