module Celerbrake
  # DeployNotifier sends deploy information to Celerbrake. The information
  # consists of:
  # - environment
  # - username
  # - repository
  # - revision
  # - version
  #
  # @api public
  # @since v3.2.0
  class DeployNotifier
    include Inspectable

    def initialize
      @config = Celerbrake::Config.instance
      @sender = SyncSender.new
    end

    # @see Celerbrake.notify_deploy
    def notify(deploy_info)
      promise = @config.check_configuration
      return promise if promise.rejected?

      promise = Celerbrake::Promise.new
      deploy_info[:environment] ||= @config.environment
      @sender.send(
        deploy_info,
        promise,
        URI.join(@config.host, "api/v4/projects/#{@config.project_id}/deploys"),
      )

      promise
    end
  end
end
