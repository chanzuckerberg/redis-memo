# frozen_string_literal: true

class RedisMemo::Middleware
  def initialize(app)
    @app = app
  end

  def call(env)
    result = nil

    RedisMemo::Cache.with_local_cache do
      RedisMemo.with_max_connection_attempts(RedisMemo::Options.max_connection_attempts) do
        result = @app.call(env)
      end
    end
    RedisMemo::Memoizable::Invalidation.drain_invalidation_queue

    result
  end
end
