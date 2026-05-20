RSpec.describe Celerbrake::Config::Processor do
  let(:notifier) { Celerbrake::NoticeNotifier.new }

  describe "#process_blocklist" do
    let(:config) { Celerbrake::Config.new(blocklist_keys: %w[a b c]) }

    context "when there ARE blocklist keys" do
      it "adds the blocklist filter" do
        described_class.new(config).process_blocklist(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::KeysBlocklist)).to be(true)
      end
    end

    context "when there are NO blocklist keys" do
      let(:config) { Celerbrake::Config.new(blocklist_keys: %w[]) }

      it "doesn't add the blocklist filter" do
        described_class.new(config).process_blocklist(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::KeysBlocklist))
          .to be(false)
      end
    end
  end

  describe "#process_allowlist" do
    let(:config) { Celerbrake::Config.new(allowlist_keys: %w[a b c]) }

    context "when there ARE allowlist keys" do
      it "adds the allowlist filter" do
        described_class.new(config).process_allowlist(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::KeysAllowlist)).to be(true)
      end
    end

    context "when there are NO allowlist keys" do
      let(:config) { Celerbrake::Config.new(allowlist_keys: %w[]) }

      it "doesn't add the allowlist filter" do
        described_class.new(config).process_allowlist(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::KeysAllowlist))
          .to be(false)
      end
    end
  end

  describe "#process_remote_configuration" do
    before do
      allow(Celerbrake::RemoteSettings).to receive(:poll)
    end

    context "when the config doesn't define a project_id" do
      let(:config) { Celerbrake::Config.new(project_id: nil) }

      it "doesn't set remote settings" do
        described_class.new(config).process_remote_configuration

        expect(Celerbrake::RemoteSettings).not_to have_received(:poll)
      end
    end

    context "when the config sets environment to 'test'" do
      let(:config) { Celerbrake::Config.new(project_id: 123, environment: 'test') }

      it "doesn't set remote settings" do
        described_class.new(config).process_remote_configuration

        expect(Celerbrake::RemoteSettings).not_to have_received(:poll)
      end
    end

    context "when the config sets :ignore_environments and :environment matches" do
      let(:config) do
        Celerbrake::Config.new(
          project_id: 123,
          ignore_environments: %w[dev],
          environment: 'dev',
        )
      end

      it "doesn't set remote settings" do
        described_class.new(config).process_remote_configuration

        expect(Celerbrake::RemoteSettings).not_to have_received(:poll)
      end
    end

    context "when the config defines a project_id and enables remote_config" do
      let(:config) do
        Celerbrake::Config.new(
          project_id: 123, environment: 'not-test', remote_config: true
        )
      end

      it "sets remote settings" do
        described_class.new(config).process_remote_configuration

        expect(Celerbrake::RemoteSettings).to have_received(:poll)
      end
    end

    context "when the config disables the remote_config option" do
      let(:config) { Celerbrake::Config.new(project_id: 123, remote_config: false) }

      it "doesn't set remote settings" do
        described_class.new(config).process_remote_configuration

        expect(Celerbrake::RemoteSettings).not_to have_received(:poll)
      end
    end
  end

  describe "#add_filters" do
    context "when there's a root directory" do
      let(:config) { Celerbrake::Config.new(root_directory: '/abc') }

      it "adds RootDirectoryFilter" do
        described_class.new(config).add_filters(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::RootDirectoryFilter))
          .to be(true)
      end

      it "adds GitRevisionFilter" do
        described_class.new(config).add_filters(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::GitRevisionFilter))
          .to be(true)
      end

      it "adds GitRepositoryFilter" do
        described_class.new(config).add_filters(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::GitRepositoryFilter))
          .to be(true)
      end

      it "adds GitLastCheckoutFilter" do
        described_class.new(config).add_filters(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::GitLastCheckoutFilter))
          .to be(true)
      end
    end

    context "when there's NO root directory" do
      let(:config) { Celerbrake::Config.new(root_directory: nil) }

      it "doesn't add RootDirectoryFilter" do
        described_class.new(config).add_filters(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::RootDirectoryFilter))
          .to be(false)
      end

      it "doesn't add GitRevisionFilter" do
        described_class.new(config).add_filters(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::GitRevisionFilter))
          .to be(false)
      end

      it "doesn't add GitRepositoryFilter" do
        described_class.new(config).add_filters(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::GitRepositoryFilter))
          .to be(false)
      end

      it "doesn't add GitLastCheckoutFilter" do
        described_class.new(config).add_filters(notifier)
        expect(notifier.has_filter?(Celerbrake::Filters::GitLastCheckoutFilter))
          .to be(false)
      end
    end
  end
end
