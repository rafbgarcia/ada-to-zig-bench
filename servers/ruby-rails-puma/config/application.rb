require "logger"
require "rails"
require "action_controller/railtie"

module BenchRubyRailsPuma
  class Application < Rails::Application
    config.load_defaults 7.1

    config.api_only = true
    config.eager_load = true
    config.hosts.clear
    config.secret_key_base = "http-json-benchmark-secret-key-base"

    config.logger = Logger.new(IO::NULL)
    config.log_level = :fatal
    config.public_file_server.enabled = false
    config.cache_store = :null_store
    config.action_controller.perform_caching = false
    config.action_dispatch.show_exceptions = :none
    config.consider_all_requests_local = false

    config.middleware.delete Rack::Runtime
    config.middleware.delete Rails::Rack::Logger
    config.middleware.delete ActionDispatch::RequestId
    config.middleware.delete ActionDispatch::RemoteIp
  end
end
