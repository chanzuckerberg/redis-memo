# typed: false

describe RedisMemo::Memoizable do
  let(:redis) { RedisMemo::Cache.redis }

  it 'checks the local cache before making redis calls' do
    RedisMemo::Cache.with_local_cache do
      mget_count = 0
      expect(redis).to receive(:mget).and_wrap_original do |method, *args|
        mget_count += 1
        method.call(*args)
      end

      expect do
        5.times do
          RedisMemo::Memoizable.checksums([
            [
              RedisMemo::Memoizable.new(id: 'test1'),
              RedisMemo::Memoizable.new(id: 'test2'),
            ],
          ])
        end
      end.to change { mget_count }.by(1)
    end
  end

  it 'creates new cache key versions if they do not exist' do
    memos = [
      RedisMemo::Memoizable.new(id: 'test1'),
      RedisMemo::Memoizable.new(id: 'test2'),
    ]

    RedisMemo::Memoizable.checksums([memos])
    memos.each do |memo|
      expect(redis.get(memo.cache_key)).to_not be_nil
    end
  end

  it 'generates the same cache key with different props ordering' do
    memo_a = RedisMemo::Memoizable.new(a: 1, b: 2)
    memo_b = RedisMemo::Memoizable.new(b: 2, a: 1)

    key_a = RedisMemo::Memoizable.checksums([[memo_a]]).first
    key_b = RedisMemo::Memoizable.checksums([[memo_b]]).first
    expect(key_a).to eq(key_b)
  end
end
