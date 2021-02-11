describe RedisMemo::ConnectionPool do
  it 'delegates methods' do
    redis = RedisMemo::ConnectionPool.new(
      RedisMemo::DefaultOptions.redis,
      size: 5,
    )

    expect(redis.ping).to eq(['PONG'])
    expect(redis.get('a')).to be_nil
    redis.set('a', '1')
    expect(redis.get('a')).to eq('1')
    expect(redis.eval("return redis.call('get', 'a')", keys: ['a'])).to eq('1')
  end
end
