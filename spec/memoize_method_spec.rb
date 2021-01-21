# typed: false

describe RedisMemo::MemoizeMethod do
  it 'replaces a method' do
    klass = Class.new do
      extend RedisMemo::MemoizeMethod

      def a
        1
      end

      memoize_method :a

      def self.b
        2
      end

      class << self
        extend RedisMemo::MemoizeMethod

        memoize_method :b
      end
    end

    default_hash = Hash.new { |h, k| h[k] = -1 }
    allow(default_hash).to receive(:include?).and_return(true)
    allow(RedisMemo::Cache).to receive(:read_multi) { default_hash }

    expect(klass.new._redis_memo_a_without_memo).to be 1
    expect(klass._redis_memo_b_without_memo).to be 2

    RedisMemo.without_memo do
      expect(klass.new.a).to be 1
      expect(klass.b).to be 2
    end

    expect(klass.new.a).to be(-1)
    expect(klass.b).to be(-1)
  end

  it 'memoizes a method' do
    klass = Class.new do
      extend RedisMemo::MemoizeMethod

      attr_accessor :calc_count

      def calc(x, y:, z: 1)
        @calc_count += 1
        x + y + z
      end

      memoize_method :calc
    end

    obj = klass.new
    obj.calc_count = 0

    5.times do
      expect(obj.calc(1, y: 2, z: 3)).to eq 6
    end

    # still a cache hit when kw args have a different ordering
    expect(obj.calc(1, z: 3, y: 2)).to eq 6

    expect(obj.calc_count).to be 1
  end

  it 'does not memoize a method if the method raise an error' do
    klass = Class.new do
      extend RedisMemo::MemoizeMethod

      attr_accessor :calc_count

      def calc(x)
        @calc_count += 1
        raise 'error'
      end

      memoize_method :calc
    end

    obj = klass.new
    obj.calc_count = 0

    5.times do
      obj.calc(1)
    rescue
      # no-ops
    end

    expect(obj.calc_count).to be 5
  end

  it 'expires by ttl' do
    klass = Class.new do
      extend RedisMemo::MemoizeMethod

      attr_accessor :calc_count

      def calc
        @calc_count += 1
      end

      memoize_method :calc, expires_in: 1
    end

    obj = klass.new
    obj.calc_count = 0

    expect(obj.calc).to be 1
    sleep(2)
    expect(obj.calc).to be 2
  end

  it 'expires by ttl dynamically' do
    klass = Class.new do
      extend RedisMemo::MemoizeMethod

      attr_accessor :calc_count

      def calc
        @calc_count += 1
      end

      memoize_method :calc, expires_in: proc { |res| res }
    end

    obj = klass.new
    obj.calc_count = 0

    expect(obj.calc).to be 1
    sleep(2)
    expect(obj.calc).to be 2
  end

  it 'memoizes calculation by version' do
    klass = Class.new do
      extend RedisMemo::MemoizeMethod

      attr_accessor :query_count

      # For real cached queries: Store the fingerprint on DB. Regenerate the
      # fingerprint when needed
      class_variable_set(:@@section_fingerprint, Random.rand)

      def fetch
        @query_count += 1
      end

      memoize_method :fetch do |obj|
        depends_on RedisMemo::Memoizable.new(
          section_fingureprint: obj.class.class_variable_get(:@@section_fingerprint),
        )
      end

      def self.add_student_to_section
        class_variable_set(:@@section_fingerprint, Random.rand)
      end

      def self.remove_student_from_section
        class_variable_set(:@@section_fingerprint, Random.rand)
      end
    end

    cached_query = klass.new
    cached_query.query_count = 0

    3.times { cached_query.fetch }
    expect(cached_query.query_count).to be 1

    klass.add_student_to_section
    3.times { cached_query.fetch }
    expect(cached_query.query_count).to be 2

    klass.remove_student_from_section
    3.times { cached_query.fetch }
    expect(cached_query.query_count).to be 3
  end

  it 'respects the global cache key version' do
    global_cache_key_version = 1

    allow(RedisMemo::DefaultOptions).to receive(:global_cache_key_version) do
      global_cache_key_version
    end

    method_context = [nil, nil, [], nil]
    cache_key_a = RedisMemo::MemoizeMethod.method_cache_keys([method_context])
    global_cache_key_version = 2
    cache_key_b = RedisMemo::MemoizeMethod.method_cache_keys([method_context])
    expect(cache_key_a).to_not eq(cache_key_b)
  end
end
