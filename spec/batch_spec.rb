# typed: false
describe RedisMemo::Batch do
  it 'loads memoized methods in batch' do
    memo = RedisMemo::Memoizable.new(id: 'test')
    klass = Class.new do
      extend RedisMemo::MemoizeMethod

      def cached_query(x)
        x
      end

      memoize_method :cached_query do |_, x|
        depends_on memo
      end

      def pure_func(x)
        x * x
      end

      memoize_method :pure_func
    end

    obj = klass.new

    expect(RedisMemo::Cache.redis).to receive(:mget)
      .exactly(3).times
      .and_call_original

    refs = []

    # set the cache for the object
    obj.pure_func(1)

    results = RedisMemo.batch do
      2.times { obj.cached_query(3) }
      refs = (1..3).map { |i| obj.pure_func(i) }

      # Cannot access the result before finishing a batch
      expect {
        refs.last.result
      }.to raise_error(RedisMemo::RuntimeError)
    end

    expect(refs.map(&:result)).to eq([1, 4, 9])
    expect(refs.first.instance_variable_get(:@computed_fresh_result)).to be(false)

    expect(results).to eq([3, 3, 1, 4, 9])
  end

  it 'does not support nesting' do
    expect {
      RedisMemo.batch do
        RedisMemo.batch {}
      end
    }.to raise_error(RedisMemo::RuntimeError)
  end

  it 'opens and closes a batch' do
    expect {
      RedisMemo.batch do
        raise 'error'
      end
    }.to raise_error('error')

    expect(RedisMemo::Batch.current).to be_nil

    # Batch can be empty
    RedisMemo.batch {}
  end
end
