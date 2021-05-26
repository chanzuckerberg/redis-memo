# typed: false

describe RedisMemo::AfterCommit do
  def memo
    RedisMemo::Memoizable.new(all: 'true')
  end

  def memo_checksum
    RedisMemo::Memoizable.__send__(:checksums, [[memo]]).first
  end

  let!(:klass) do
    _memo = memo
    Class.new do
      extend RedisMemo::MemoizeMethod

      attr_accessor :calc_count

      def initialize
        @calc_count = 0
      end

      def calc
        @calc_count += 1
      end

      memoize_method :calc do |_arg|
        depends_on _memo
      end
    end
  end
  let!(:obj) { klass.new }

  let!(:redis_stats) do
    {
      mget_count: 0,
      set_count: 0,
      invalidation_count: 0,
    }
  end

  before(:each) do
    allow(RedisMemo::Cache.redis).to receive(:mget).and_wrap_original do |method, *args|
      redis_stats[:mget_count] += 1
      method.call(*args)
    end

    allow(RedisMemo::Cache.redis).to receive(:set).and_wrap_original do |method, *args|
      redis_stats[:set_count] += 1
      method.call(*args)
    end

    allow(RedisMemo::Cache.redis).to receive(:run_script).and_wrap_original do |method, *args|
      redis_stats[:invalidation_count] += 1
      method.call(*args)
    end
  end

  def calc(x)
    x.times { obj.calc }
  end

  def invalidate_all
    RedisMemo::Memoizable.invalidate([memo])
  end

  def calc_count
    obj.calc_count
  end

  def mget_count
    redis_stats[:mget_count]
  end

  def set_count
    redis_stats[:set_count]
  end

  def invalidation_count
    redis_stats[:invalidation_count]
  end

  def redis
    RedisMemo::Cache.redis
  end

  def with_local_cache(&blk)
    RedisMemo::Cache.with_local_cache(&blk)
  end

  def maybe_with_local_cache(use_local_cache:, &blk)
    if use_local_cache
      with_local_cache(&blk)
    else
      yield
    end
  end

  context 'when saving cache results in transactions' do
    it 'saves immediately with local cache' do
      ActiveRecord::Base.transaction do
        with_local_cache do
          expect {
            expect {
              expect { calc(5) }.to change { calc_count }.by(1)
            }.to change { mget_count }.by(2)
          }.to change { set_count }.by(1)
        end
      end
    end

    it 'saves immediately without local cache' do
      ActiveRecord::Base.transaction do
        expect {
          expect {
            expect { calc(5) }.to change { calc_count }.by(1)
          }.to change { mget_count }.by(6)
          # The first calc call would MGET memo_version and method_cache_result
          # The reset of the calc calls only MGET method_cache_result (cache hit)
        }.to change { set_count }.by(1)
      end
    end
  end

  it 'does not send out invalidation calls until the transaction has commited' do
    expect {
      ActiveRecord::Base.transaction do
        expect {
          invalidate_all
        }.to change { invalidation_count }.by(0)
      end
    }.to change { invalidation_count }.by(1)
  end

  it 'does not send out invalidation calls if the transaction has rolled back' do
    expect {
      ActiveRecord::Base.transaction do
        invalidate_all
        raise ActiveRecord::Rollback
      end
    }.to change { invalidation_count }.by(0)
  end

  it 'has cache results from a transaction after commit' do
    ActiveRecord::Base.transaction do
      calc(1)
    end

    expect {
      expect {
        expect { calc(1) }.to change { calc_count }.by(0)
      }.to change { mget_count }.by(2)
    }.to change { set_count }.by(0)
  end

  it 'resets if the transaction has rolled back' do
    with_local_cache do
      ActiveRecord::Base.transaction do
        calc(1)
        raise ActiveRecord::Rollback
      end

      expect {
        expect {
          expect { calc(5) }.to change { calc_count }.by(1)
        }.to change { mget_count }.by(2)
      }.to change { set_count }.by(1)
    end
  end

  context 'when a memo has been invalidated' do
    def calc_and_invalidate(use_local_cache:)
      maybe_with_local_cache(use_local_cache: use_local_cache) do
        old_memo_checksum = memo_checksum
        old_memo_version = redis.get(memo.cache_key)

        ActiveRecord::Base.transaction do
          calc(5)
          invalidate_all

          yield

          new_memo_checksum = memo_checksum
          visible_memo_version = redis.get(memo.cache_key)

          # The new_memo_checksum is different from the old because it's using
          # the latest memo version -- it's only visible to the current Ruby process
          expect(new_memo_checksum).not_to eq(old_memo_checksum)

          # The actual memo version that's visible to other process remains the
          # same until the transaction has commited
          expect(visible_memo_version).to eq(old_memo_version)
        end

        new_memo_version = redis.get(memo.cache_key)
        expect(new_memo_version).not_to eq(old_memo_version)

        # The cached results in the transaction is now publicly available
        expect { calc(5) }.to change { calc_count }.by(0)
      end
    end

    context 'without local cache' do
      it 'uses the latest memo versions' do
        calc_and_invalidate(use_local_cache: false) do
          expect {
            expect {
              expect { calc(5) }.to change { calc_count }.by(1)
            }.to change { mget_count }.by(5)
            # Try to get the method cache result on Redis associated with a
            # pending version -- cache miss the first time, later we get cache
            # hits
          }.to change { set_count }.by(1)
        end
      end
    end

    context 'with local cache' do
      it 'uses the latest memo versions' do
        calc_and_invalidate(use_local_cache: true) do
          expect {
            expect {
              expect { calc(5) }.to change { calc_count }.by(1)
            }.to change { mget_count }.by(1)
            # Try to get the method cache result on Redis associated with a
            # pending version -- cache miss
          }.to change { set_count }.by(1)
        end
      end
    end
  end

  context 'when a memo has been invalidated by other processes (race condition)' do
    def calc_and_invalidate(use_local_cache:)
      maybe_with_local_cache(use_local_cache: use_local_cache) do
        ActiveRecord::Base.transaction do
          calc(1)
          invalidate_all

          # race condition!
          redis.set(memo.cache_key, 'another_version')

          calc(1)
        end

        yield
      end
    end

    context 'with local cache' do
      it 'does not care about the changes made by other processes' do
        calc_and_invalidate(use_local_cache: true) do
          expect {
            expect {
              expect { calc(1) }.to change { calc_count }.by(0)
            }.to change { mget_count }.by(0)
          }.to change { set_count }.by(0)
        end
      end
    end

    context 'without local cache' do
      it 'ignores existing cached results and recomputes' do
        calc_and_invalidate(use_local_cache: false) do
          expect {
            expect {
              expect { calc(1) }.to change { calc_count }.by(1)
            }.to change { mget_count }.by(2)
          }.to change { set_count }.by(1)
        end
      end
    end
  end
end
