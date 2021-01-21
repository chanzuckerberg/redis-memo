# typed: false
class RedisMemo::Middleware
  def initialize(app)
    @app = app
  end

  def call(env)
    result = nil

    RedisMemo::Cache.with_local_cache do
      result = @app.call(env)
    end
    RedisMemo::Memoizable::Invalidation.drain_invalidation_queue

    result
  end
end
