# typed: false

describe RedisMemo::Cache do
  let!(:redis) { RedisMemo::Cache.redis }
  let!(:cache) { RedisMemo::Cache }

  before(:each) do
    allow(RedisMemo::DefaultOptions).to receive(:logger) { nil }
  end

  it 'checks the request store before making redis call before get' do
    RedisMemo::Cache.with_local_cache do
      redis.set('a', Marshal.dump(1))

      expect(redis).to receive(:mget).once.and_call_original
      5.times { cache.read_multi('a') }

      cache.write('b', Marshal.dump(2))
      5.times { cache.read_multi('b') }

      5.times { cache.read_multi('a', 'b') }
    end
  end

  it 'checks the request store before making redis call before mget' do
    RedisMemo::Cache.with_local_cache do
      expect(redis).to receive(:mget).once.and_call_original
      cache.read_multi('a', 'b')

      cache.write('a', 1)
      cache.write('b', 2)

      expect(cache.read_multi('a', 'b')).to eq({
        'a' => 1, 'b' => 2,
      })
    end
  end

  it 'caches nil value' do
    cache.write('a', nil)
    val = cache.read_multi('a')
    expect(val.include?('a')).to be(true)
    expect(val['a']).to be_nil
  end

  it 'does not interrupt on redis errors' do
    error_handler = proc {}
    allow(RedisMemo::DefaultOptions).to receive(:redis_error_handler) { error_handler }

    allow_any_instance_of(Redis).to receive(:mget) do
      raise ::Redis::BaseConnectionError
    end
    allow_any_instance_of(Redis).to receive(:mapped_mget) do
      raise ::Redis::BaseConnectionError
    end
    allow_any_instance_of(Redis).to receive(:set) do
      raise ::Redis::BaseConnectionError
    end

    klass = Class.new do
      extend RedisMemo::MemoizeMethod

      attr_accessor :count

      def exec
        @count += 1
      end

      memoize_method :exec
    end

    expect(error_handler).to receive(:call).at_least(5).times

    obj = klass.new
    obj.count = 0
    5.times { obj.exec }
    expect(obj.count).to be 5
  end

  it 'raises an error if configured' do
    allow(RedisMemo::DefaultOptions).to receive(:async) do
      proc { |&blk| Thread.new { blk.call } }
    end
    allow_any_instance_of(Redis).to receive(:mget) do
      raise ::Redis::BaseConnectionError
    end
    allow_any_instance_of(Redis).to receive(:mapped_mget) do
      raise ::Redis::BaseConnectionError
    end
    allow_any_instance_of(Redis).to receive(:set) do
      raise ::Redis::BaseConnectionError
    end

    store = RedisMemo::Cache
    expect(store.read_multi('a', 'b')).to eq({})
    expect {
      store.write('a', 'b')
    }.to_not raise_error

    expect {
      store.read_multi('a', 'b', raise_error: true)
    }.to raise_error(RedisMemo::Cache::Rescuable)

    expect {
      # the error is trapped in the thread
      store.write('a', 'b', raise_error: true, disable_async: false)
    }.not_to raise_error

    expect {
      store.write('a', 'b', raise_error: true, disable_async: true)
    }.to raise_error(RedisMemo::Cache::Rescuable)
  end
end
