# typed: false

describe RedisMemo::Memoizable::Invalidation do
  context 'with a DAG' do
    before(:each) do
      stub_const('RedisMemoSpecDAG', Class.new do
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
      end)
    end

    it 'makes one round trip to fetch the memo versions' do
      RedisMemo::Cache.with_local_cache do
        val = 0
        klass = Class.new do
          extend RedisMemo::MemoizeMethod

          attr_accessor :calc_count

          def calc(_x)
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

        def calc(_x)
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

    context 'with dependencies of other methods' do
      klass = Class.new do
        extend RedisMemo::MemoizeMethod

        attr_accessor :calc_count
        attr_reader :id

        def initialize(id)
          @id = id
        end

        def calc(_x)
          @calc_count += 1
        end

        def calc_b_c(_x)
          @calc_count += 1
        end

        memoize_method :calc_b_c do |obj, x|
          depends_on RedisMemoSpecDAG.b(x)
          depends_on RedisMemoSpecDAG.c(x)
          depends_on RedisMemo::Memoizable.new(id: obj.id, val: x)
        end

        memoize_method :calc do |obj, x|
          depends_on obj.dependency_of(:calc_b_c, x)
          depends_on RedisMemo::Memoizable.new(val: x)
        end
      end
      obj = klass.new(:e)
      obj.calc_count = 0
      val = 0

      it 'pulls in dependencies defined by other methods' do
        [
          RedisMemoSpecDAG.a(val),
          RedisMemoSpecDAG.b(val),
          RedisMemoSpecDAG.c(val),
          RedisMemo::Memoizable.new(id: obj.id, val: val),
          RedisMemo::Memoizable.new(val: val),
        ].each do |memo|
          expect {
            RedisMemo::Memoizable.invalidate([memo])
            5.times { obj.calc(val) }
          }.to change { obj.calc_count }.by(1)
        end
      end

      it 'locally caches computation to extract dependencies' do
        RedisMemo::Cache.with_local_cache do
          expect(RedisMemo::MemoizeMethod).to receive(:extract_dependencies).twice.and_call_original
          5.times { obj.calc_b_c(val) }
          5.times { obj.calc(val) }
        end
      end
    end

    context 'for different parameter formats in the dependency block' do
      let(:klass) do
        Class.new do
          extend RedisMemo::MemoizeMethod
        end
      end

      let(:obj) { klass.new }

      def add_test_case(named_args)
        # Expect dependencies to only get extracted once
        expect(RedisMemo::MemoizeMethod).to receive(:extract_dependencies).once.and_call_original
        yield

        # Expect that the mapped args are correct
        depends_on = obj.singleton_class.instance_variable_get(:@__redis_memo_method_dependencies)[:test]
        expect(RedisMemo::Cache.local_dependency_cache[obj.class][depends_on].key?(named_args)).to be true
      end

      before(:each) do
        obj.class_eval { def test(*args, **kwargs); end }
      end

      it 'works using a dependency block with a splat' do
        obj.class_eval do
          memoize_method(:test) { |_, _, *args, _, a| }
        end
        RedisMemo::Cache.with_local_cache do
          add_test_case([2, 3, 5]) { 5.times { obj.test(1, 2, 3, 4, 5) } }
          add_test_case([2, 3, 5, { b: 1 }]) { 5.times { obj.test(1, 2, 3, 4, 5, b: 1) } }
        end
      end

      it 'works using a dependency block with keyword args' do
        obj.class_eval do
          memoize_method(:test) { |_, *args, a:, b:, **kwargs| }
        end
        RedisMemo::Cache.with_local_cache do
          add_test_case([1, 2, 3, { a: 4, b: 5, c: 6, d: 6 }]) { 5.times { obj.test(1, 2, 3, a: 4, b: 5, c: 6, d: 6) } }
          add_test_case([1, 2, 3, { a: 5, b: 6, c: 5 }]) { 5.times { obj.test(1, 2, 3, a: 5, c: 5, b: 6) } }
        end
      end

      it 'works using a dependency block with anonomyous splats' do
        obj.class_eval do
          memoize_method(:test) { |_, a, b, *, c, d:, **| }
        end
        RedisMemo::Cache.with_local_cache do
          add_test_case([1, 1, 1, { d: 3 }]) do
            5.times { obj.test(1, 1, 2, 3, 1, d: 3) }
            5.times { obj.test(1, 1, 3, 4, 5, 1, d: 3, e: 3) }
          end
        end
      end

      it 'raises an error when a block is a parameter in the dependency block' do
        obj.class_eval do
          memoize_method(:test) { |_, *, **, &blk| }
        end
        RedisMemo::Cache.with_local_cache do
          expect {
            obj.test(1)
          }.to raise_error(RedisMemo::ArgumentError)
        end
      end
    end

    it 'raises an error when it depends on a non-memoized method' do
      klass = Class.new do
        extend RedisMemo::MemoizeMethod

        def non_memoized_method(x); end

        def calc(x); end

        memoize_method :calc do |obj, x|
          depends_on obj.dependency_of(:non_memoized_method, x)
        end
      end
      obj = klass.new
      expect {
        obj.calc(0)
      }.to raise_error(RedisMemo::ArgumentError)
    end

    it 'raises an error when passed an invalid dependency' do
      klass = Class.new do
        extend RedisMemo::MemoizeMethod

        def calc(x); end

        memoize_method :calc do |_obj, _x|
          depends_on Class.new
        end
      end
      obj = klass.new
      expect {
        obj.calc(0)
      }.to raise_error(RedisMemo::ArgumentError)
    end
  end

  context 'with a directed cyclic graph' do
    before(:each) do
      stub_const('RedisMemoSpecDG', Class.new do
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
      end)
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

  context 'with an arel dependency' do
    before(:each) do
      stub_const('SpecModel', Class.new(ActiveRecord::Base) do
        extend RedisMemo::MemoizeMethod
        extend RedisMemo::MemoizeQuery

        attr_accessor :calc_count

        def calc
          SpecModel.where(a: a).to_a
          @calc_count += 1
        end

        memoize_method :calc do |record|
          depends_on SpecModel.where(a: record.a)
        end
      end)

      ActiveRecord::Base.connection.execute 'drop table if exists spec_models'
      ActiveRecord::Base.connection.create_table :spec_models do |t|
        t.integer 'a', default: 0
        t.integer 'not_memoized', default: 0
      end

      SpecModel.memoize_table_column :a, editable: false
    end

    it 'pulls in dependencies from an activerecord relation' do
      record = SpecModel.create!(a: 1)
      record.calc_count = 0
      expect {
        5.times { record.calc }
      }.to change { record.calc_count }.by(1)
      expect {
        record.update!(a: 2)
        5.times { record.calc }
      }.to change { record.calc_count }.by(1)
    end

    it 'locally caches computation to extract dependencies for an arel query' do
      record = SpecModel.create!(a: 1)
      record.calc_count = 0
      RedisMemo::Cache.with_local_cache do
        expect(RedisMemo::MemoizeMethod).to receive(:extract_dependencies).twice.and_call_original
        expect {
          5.times { record.calc }
        }.to change { record.calc_count }.by(1)
      end
    end

    it 'falls back to the uncached method when a dependent arel query is not memoized' do
      record = SpecModel.create!(a: 1, not_memoized: 1)
      record.calc_count = 0
      record.class_eval do
        def calc_2
          @calc_count += 2
        end

        memoize_method :calc_2 do |r|
          depends_on SpecModel.where(not_memoized: r.not_memoized)
        end
      end
      expect {
        5.times { record.calc_2 }
      }.to change { record.calc_count }.by(10)
    end

    it 'falls back to the uncached method when queries are disabled for caching', :disable_cached_select do
      allow(ActiveRecord::Base.connection).to receive(:respond_to?).and_call_original
      allow(ActiveRecord::Base.connection).to receive(:respond_to?).with(:dependency_of).and_return(false)
      record = SpecModel.create!(a: 1)
      record.calc_count = 0
      expect {
        5.times { record.calc }
      }.to change { record.calc_count }.by(5)
    end

    it 'supports conditional memoization by raising a WithoutMemoization error' do
      record = SpecModel.create!(a: 1)
      record.calc_count = 0

      record.class_eval do
        def calc_2(without_memoization: false)
          @calc_count += 2
        end

        memoize_method :calc_2 do |r, without_memoization|
          raise RedisMemo::WithoutMemoization if without_memoization

          depends_on SpecModel.where(a: r.a)
        end
      end
      expect {
        5.times { record.calc_2 }
      }.to change { record.calc_count }.by(2)
      expect {
        5.times { record.calc_2(without_memoization: true) }
      }.to change { record.calc_count }.by(10)
    end
  end
end
