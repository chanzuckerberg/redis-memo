# frozen_string_literal: true
class RedisMemo::Railtie < Rails::Railtie
  initializer 'request_store.insert_middleware' do |app|
    if ActionDispatch.const_defined? :RequestId
      app.config.middleware.insert_after ActionDispatch::RequestId, RedisMemo::Middleware
    else
      app.config.middleware.insert_after Rack::MethodOverride, RedisMemo::Middleware
    end
  end
end
