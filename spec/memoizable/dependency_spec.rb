# typed: false

describe RedisMemo::Memoizable::Invalidation do
  context 'with a DAG' do
    module RedisMemoSpecDAG
        # a ->   b   ->  d
        #   \->  c   /
      def self.a(val)
        RedisMemo::Memoizable.new(id: :a, val: val)
      end

      def self.b(val)
        RedisMemo::Memoizable.new(id: :b, val: val) do
          depends_on RedisMemoSpecDAG.a(val)
        end
      end

      def self.c(val)
        RedisMemo::Memoizable.new(id: :c, val: val) do
          depends_on RedisMemoSpecDAG.a(val)
        end
      end

      def self.d(val)
        RedisMemo::Memoizable.new(id: :d, val: val) do
          depends_on RedisMemoSpecDAG.b(val)
          depends_on RedisMemoSpecDAG.c(val)
        end
      end
    end

    it 'makes one round trip to fetch the memo versions' do
      RedisMemo::Cache.with_local_cache do
        val = 0
        klass = Class.new do
          extend RedisMemo::MemoizeMethod

          attr_accessor :calc_count

          def calc(x)
            @calc_count += 1
          end

          memoize_method :calc do
            depends_on RedisMemoSpecDAG.d(val)
          end
        end

        obj = klass.new
        obj.calc_count = 0

        expect_any_instance_of(Redis).to receive(:mget).twice.and_call_original
        5.times { obj.calc(1) }
        expect(obj.calc_count).to be(1)
      end
    end

    it 're-calculates when the downstream memos have changed' do
      val = 0
      klass = Class.new do
        extend RedisMemo::MemoizeMethod

        attr_accessor :calc_count

        def calc(x)
          @calc_count += 1
        end

        memoize_method :calc do
          depends_on RedisMemoSpecDAG.d(val)
        end
      end

      obj = klass.new
      obj.calc_count = 0

      expect {
        5.times { obj.calc(1) }
      }.to change { obj.calc_count }.by(1)

      expect {
        RedisMemo::Memoizable.invalidate([RedisMemoSpecDAG.a(val)])
        5.times { obj.calc(1) }
      }.to change { obj.calc_count }.by(1)

      expect {
        RedisMemo::Memoizable.invalidate([RedisMemoSpecDAG.b(val)])
        5.times { obj.calc(1) }
      }.to change { obj.calc_count }.by(1)

      expect {
        RedisMemo::Memoizable.invalidate([RedisMemoSpecDAG.c(val)])
        5.times { obj.calc(1) }
      }.to change { obj.calc_count }.by(1)

      expect {
        RedisMemo::Memoizable.invalidate([RedisMemoSpecDAG.d(val)])
        5.times { obj.calc(1) }
      }.to change { obj.calc_count }.by(1)
    end
  end

  context 'with a directed cyclic graph' do
    module RedisMemoSpecDG
      # a <-> b
      def self.a(val)
        RedisMemo::Memoizable.new(id: :a, val: val) do
          depends_on RedisMemoSpecDG.b(val)
        end
      end

      def self.b(val)
        RedisMemo::Memoizable.new(id: :b, val: val) do
          depends_on RedisMemoSpecDG.a(val)
        end
      end
    end

    it 'still works' do
      val = 0
      klass = Class.new do
        extend RedisMemo::MemoizeMethod

        attr_accessor :calc_count

        def calc_a
          @calc_count += 1
        end

        memoize_method :calc_a do
          depends_on RedisMemoSpecDG.a(val)
        end

        def calc_b
          @calc_count += 1
        end

        memoize_method :calc_b do
          depends_on RedisMemoSpecDG.b(val)
        end
      end

      obj = klass.new
      obj.calc_count = 0

      expect {
        5.times { obj.calc_a }
      }.to change { obj.calc_count }.by(1)

      expect {
        5.times { obj.calc_b }
      }.to change { obj.calc_count }.by(1)

      expect {
        RedisMemo::Memoizable.invalidate([RedisMemoSpecDG.a(val)])
        5.times { obj.calc_a }
      }.to change { obj.calc_count }.by(1)

      expect {
        RedisMemo::Memoizable.invalidate([RedisMemoSpecDG.b(val)])
        5.times { obj.calc_b }
      }.to change { obj.calc_count }.by(1)
    end
  end
end
