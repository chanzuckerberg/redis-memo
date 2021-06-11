RSpec.describe RedisMemo::MemoizeQuery::CachedSelect::BindParams do
  it 'unions' do
    left = described_class.new
    left.params[1] << { a: 1 }

    right = described_class.new
    right.params[1] << { b: 2 }

    bp = left.union(right)
    bp.extract!
    expect(bp.params[1].to_a).to eq([{ a: 1 }, { b: 2 }])

    left.params[1] << { b: 3 }
    bp.extract!
    expect(bp.params[1].to_a).to eq([{ a: 1 }, { b: 3 }, { b: 2 }])
  end

  it 'products' do
    left = described_class.new
    left.params[1] << { a: 1 }

    right = described_class.new
    right.params[1] << { b: 2 }

    bp = left.product(right)
    bp.extract!
    expect(bp.params[1].to_a).to eq([{ a: 1, b: 2 }])
  end

  it 'excludes conflict query conditions' do
    left = described_class.new
    left.params[1] << { a: 1 }
    left.params[1] << { b: 1 }

    right = described_class.new
    right.params[1] << { a: 2 }
    right.params[1] << { b: 2 }

    bp = left.product(right)
    bp.extract!
    expect(bp.params[1].to_a).to eq([{ b: 2, a: 1 }, { a: 2, b: 1 }])
  end

  it 'does not cache query with too many dependencies' do
    fake_colums = Class.new do
      def self.include?(*_args)
        true
      end
    end
    allow(RedisMemo::DefaultOptions).to receive(:max_query_dependency_size).and_return(100)
    allow(RedisMemo::MemoizeQuery).to receive(:memoized_columns).with(anything).and_return(fake_colums)

    left = described_class.new
    left.params[1] << { a: 1 }

    right = described_class.new
    right.params[1] << { b: 1 }

    bp = left.product(right)
    expect(bp.should_cache?).to eq(true)

    (2..11).each do |i|
      left.params[1] << { a: i }
      right.params[1] << { b: i }
    end

    expect(bp.should_cache?).to eq(false)
  end

  it 'does not cache query with non-dependencies' do
    fake_colums = Class.new do
      def self.include?(*_args)
        false
      end
    end
    allow(RedisMemo::MemoizeQuery).to receive(:memoized_columns).with(anything).and_return(fake_colums)

    left = described_class.new
    left.params[1] << { a: 1 }

    expect(left.should_cache?).to eq(false)
  end
end
