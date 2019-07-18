require 'sidekiq'
require File.join(File.dirname(__FILE__), "..", "config", "environment")
DEFAULT_DOKKU_SOCKET_PATH ="/var/run/dokku-daemon/dokku-daemon.sock"
DEFAULT_DOCKER_SOCKET_PATH ="/var/run/docker.sock"
DEFAULT_TIMEOUT = ENV["COMMAND_TIMEOUT"].nil? ? 60 : ENV["COMMAND_TIMEOUT"].to_i
Sidekiq.configure_server do |config|
  config.redis = { url: ENV["REDIS_URL"] }
end

class CommandRunner
  include Sidekiq::Worker
  def perform(command_id)
    logger.info "[CommandRunner] #{command_id}"

    begin
      @command = Command.get!(command_id)
      Timeout.timeout(DEFAULT_TIMEOUT) do
        socket = UNIXSocket.new(DEFAULT_DOKKU_SOCKET_PATH)
        if command.command.include? "docker"
          socket = UNIXSocket.new(DEFAULT_DOCKER_SOCKET_PATH)
          command.command = command.command.slice! "docker "
        end
        sleep(1) # Give socket 1 sec
        logger.info "[CommandRunner] Sending the command"
        socket.puts(@command.command)
        logger.info "[CommandRunner] Waiting for the result"
        result = socket.gets("\n")
        logger.info "[CommandRunner] Result: #{result}"
        @command.update!(result: result, ran_at: DateTime.now)
        CallbackWorker.perform_async(@command.id) unless @command.callback_url.nil?
        socket.close
      end
    rescue Timeout::Error
      logger.info "[CommandRunner] Command Timed Out after #{DEFAULT_TIMEOUT}"
      result = {ok: false, output: "command_timed_out"}.to_json.to_s
      @command.update!(result: result, ran_at: DateTime.now)
      socket.close if defined? socket
    rescue Exception => e
      logger.info "[CommandRunner] Exception"
      logger.info e
      result = {ok: false, output: e.message}.to_json.to_s
      @command.update!(result: result, ran_at: DateTime.now)
      socket.close if defined? socket
    end
    return @command
  end
end
