# typed: false

describe RedisMemo::Redis do
  before(:each) do
    stub_const('FakeClient', Class.new do
      attr_reader :id

      def initialize(id)
        @id = id
      end

      def get(*); end

      def set(*); end
    end)
  end

  it 'distributes keys' do
    clients = [:a, :b, :c].map { |id| [id, FakeClient.new(id)] }.to_h

    allow(Redis).to receive(:new) do |options|
      clients[options[:key]]
    end

    client = RedisMemo::Redis.new(clients.keys.map { |key| { key: key } })

    clients.each do |_, c|
      expect(c).to receive(:get).at_least(:once)
    end

    (0..6).each { |i| client.get("record-id-#{i}") }
  end

  it 'randomly selects a read replica to read from' do
    client = RedisMemo::Redis::WithReplicas.new([
      { db: 0 },
      { db: 1 },
      { db: 2 },
    ])
    replica1, replica2 = client.instance_variable_get(:@replicas)

    # This test case might fail due since we're testing the random selection
    # behavior. The probablity of the failing the test is very low:
    #
    #   (1 / 2) ^ 100 = 7.8886091e-31
    #
    expect(replica1).not_to receive(:set)
    expect(replica1).to receive(:get).at_least(:once)

    expect(replica2).not_to receive(:set)
    expect(replica2).to receive(:get).at_least(:once)

    (0..5).each do |i|
      client.set("redis-memo-id-#{i}", 1)
    end

    # (1/2)^100
    100.times do
      client.get('redis-memo-id')
    end
  end

  it 'returns a hash when calling mapped_mget' do
    client = RedisMemo::Redis::WithReplicas.new([{ db: 0 }])
    expect(client.mapped_mget('a').is_a?(Hash)).to be(true)
  end

  context 'run_script' do
    let(:lua_script) { "redis.call('set', KEYS[1], ARGV[1])" }
    let(:script_sha) { Digest::SHA1.hexdigest(lua_script) }
    let(:client) { RedisMemo::Redis.new }

    before(:each) do
      client.script(:flush)
    end

    it 'calls evalsha after a script is already loaded' do
      # When the script sha isn't loaded on Redis, it should fall back to calling eval
      expect(client).to receive(:evalsha).once.and_call_original
      expect(client).to receive(:eval).once.and_call_original
      client.run_script(lua_script, script_sha, keys: ['cache_key'], argv: ['cache_value'])

      # Subsequent calls should use evalsha
      5.times do
        expect(client).to receive(:evalsha).and_call_original
        expect(client).to_not receive(:eval)
        client.run_script(lua_script, script_sha, keys: ['cache_key'], argv: ['cache_value'])
      end
    end

    it 'only rescues NOSCRIPT errors from redis' do
      allow(client).to receive(:evalsha).and_raise(Redis::CommandError)
      expect {
        client.run_script(lua_script, script_sha)
      }.to raise_error(Redis::CommandError)
    end
  end
end
