# typed: false

describe RedisMemo::Memoizable::Invalidation do
  let(:queue) { Queue.new }
  let(:redis) { RedisMemo::Cache.redis }

  before(:each) do
    RedisMemo::Memoizable::Invalidation.class_variable_set(:@@invalidation_queue, queue)
  end

  it 'bumps version' do
    RedisMemo::Memoizable::Invalidation.bump_version(
      RedisMemo::Memoizable::Invalidation::Task.new('key', 'version', nil),
    )
    version = redis.get('key')
    expect(version).to eq('version')

    RedisMemo::Memoizable::Invalidation.bump_version(
      RedisMemo::Memoizable::Invalidation::Task.new('key', 'new_version', nil),
    )
    new_version = redis.get('key')
    expect(new_version).not_to eq(version)
    expect(new_version).not_to eq('new_version')

    RedisMemo::Memoizable::Invalidation.bump_version(
      RedisMemo::Memoizable::Invalidation::Task.new('key', 'new_version', new_version),
    )
    new_version = redis.get('key')
    expect(new_version).to eq('new_version')
  end

  it 'saves failed invalidation requests and retries' do
    klass = Class.new do
      attr_accessor :retry_count

      def initialize
        @retry_count = 0
      end

      def eval(*)
        return unless @retry_count < 3

        @retry_count += 1
        raise Redis::BaseConnectionError
      end

      def with(*)
        yield self
      end
    end
    flaky_redis = klass.new
    allow(RedisMemo::Cache).to receive(:redis) do
      flaky_redis
    end
    queue << RedisMemo::Memoizable::Invalidation::Task.new('key', 'version', nil)

    RedisMemo::Memoizable::Invalidation.drain_invalidation_queue
    expect(queue.empty?).to be false

    3.times do
      RedisMemo::Memoizable::Invalidation.drain_invalidation_queue
    end
    expect(queue.empty?).to be true
  end

  it 'retries invalidation async if configured' do
    allow(RedisMemo::DefaultOptions).to receive(:async) do
      proc { |&blk| Thread.new { blk.call } }
    end

    klass = Class.new do
      attr_accessor :done

      def eval(*)
        sleep(1) until @done
      end

      def with(*)
        yield self
      end
    end

    slow_redis = klass.new
    slow_redis.done = false
    allow(RedisMemo::Cache).to receive(:redis) do
      slow_redis
    end

    # The actual version bumping might happen in some other test cases; so
    # here we're using a uniq key that's only used in this spec to avoid
    # affecting other test cases
    queue << RedisMemo::Memoizable::Invalidation::Task.new('__async_key__', 'version', nil)

    # This code is run async, or it will never complete
    RedisMemo::Memoizable::Invalidation.drain_invalidation_queue
    slow_redis.done = true
  end

  it 'clears the local cache' do
    RedisMemo::Cache.with_local_cache do
      memo = RedisMemo::Memoizable.new(id: 'test')
      klass = Class.new do
        extend RedisMemo::MemoizeMethod

        attr_accessor :calc_count

        def calc(_x)
          @calc_count += 1
        end

        memoize_method :calc do
          depends_on memo
        end
      end

      obj = klass.new
      obj.calc_count = 0

      5.times { obj.calc(1) }
      expect(obj.calc_count).to be 1

      expect(RedisMemo::Memoizable::Invalidation).to receive(:bump_version).once.and_call_original
      RedisMemo::Memoizable.invalidate([memo])

      5.times { obj.calc(1) }
      expect(obj.calc_count).to be 2
    end
  end
end
