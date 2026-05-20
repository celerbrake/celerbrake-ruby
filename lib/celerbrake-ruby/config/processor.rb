module Celerbrake
  class Config
    # Processor is a helper class, which is responsible for setting default
    # config values, default notifier filters and remote configuration changes.
    #
    # @since v5.0.0
    # @api private
    class Processor
      # @param [Celerbrake::Config] config
      # @return [Celerbrake::Config::Processor]
      def self.process(config)
        new(config).process
      end

      # @param [Celerbrake::Config] config
      def initialize(config)
        @config = config
        @blocklist_keys = @config.blocklist_keys
        @allowlist_keys = @config.allowlist_keys
        @project_id = @config.project_id
        @poll_callback = Celerbrake::RemoteSettings::Callback.new(config)
      end

      # @param [Celerbrake::NoticeNotifier] notifier
      # @return [void]
      def process_blocklist(notifier)
        return if @blocklist_keys.none?

        blocklist = Celerbrake::Filters::KeysBlocklist.new(@blocklist_keys)
        notifier.add_filter(blocklist)
      end

      # @param [Celerbrake::NoticeNotifier] notifier
      # @return [void]
      def process_allowlist(notifier)
        return if @allowlist_keys.none?

        allowlist = Celerbrake::Filters::KeysAllowlist.new(@allowlist_keys)
        notifier.add_filter(allowlist)
      end

      # @return [Celerbrake::RemoteSettings]
      def process_remote_configuration
        return unless @config.remote_config
        return unless @project_id

        # Never poll remote configuration in the test environment.
        return if @config.environment == 'test'

        # If the current environment is ignored, don't try to poll remote
        # configuration.
        return if @config.ignore_environments.include?(@config.environment)

        RemoteSettings.poll(@project_id, @config.remote_config_host) do |data|
          @poll_callback.call(data)
        end
      end

      # @param [Celerbrake::NoticeNotifier] notifier
      # @return [void]
      def add_filters(notifier)
        return unless @config.root_directory

        [
          Celerbrake::Filters::RootDirectoryFilter,
          Celerbrake::Filters::GitRevisionFilter,
          Celerbrake::Filters::GitRepositoryFilter,
          Celerbrake::Filters::GitLastCheckoutFilter,
        ].each do |filter|
          next if notifier.has_filter?(filter)

          notifier.add_filter(filter.new(@config.root_directory))
        end
      end
    end
  end
end
