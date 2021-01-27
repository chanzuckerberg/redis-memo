# typed: false
describe RedisMemo::MemoizeQuery do
  class RedisMemoSpecModel < ActiveRecord::Base
    extend RedisMemo::MemoizeMethod
    extend RedisMemo::MemoizeQuery

    enum my_enum: {x: 0, y: 1}

    class << self
      attr_accessor :spec_context

      def a_count(value)
        spec_context.expect_to_use_redis { where(a: value).count }
      end

      def b_count(value)
        spec_context.expect_to_use_redis { where(b: value).count }
      end

      def ab_count(a:, b:)
        spec_context.expect_to_use_redis { where(a: a, b: b).count }
      end
    end
  end

  before(:all) do
    # Drop the table in case the test case was aborted
    ActiveRecord::Base.connection.execute 'drop table if exists redis_memo_spec_models'
    ActiveRecord::Base.connection.create_table :redis_memo_spec_models do |t|
      t.integer 'a', default: 0
      t.integer 'b', default: 0
      t.integer 'not_memoized', default: 0
      t.integer 'my_enum', default: 0
    end

    RedisMemoSpecModel.memoize_table_column :id, editable: false
    RedisMemoSpecModel.memoize_table_column :a
    RedisMemoSpecModel.memoize_table_column :b
    RedisMemoSpecModel.memoize_table_column :my_enum
    RedisMemoSpecModel.memoize_table_column :a, :b
  end

  after(:all) do
    # Clean up
    ActiveRecord::Base.connection.execute 'drop table if exists redis_memo_spec_models'
  end

  let(:model_class) { RedisMemoSpecModel }
  let!(:redis) { RedisMemo::Cache.redis }

  before(:each) do
    @mget_count = 0
    allow(redis).to receive(:mget).and_wrap_original do |method, *args|
      @mget_count += 1
      method.call(*args)
    end
    model_class.spec_context = self
  end

  def expect_mget_count(count)
    result = nil
    expect { result = yield }.to change { @mget_count }.by(count)
    result
  end

  def expect_mget_count_at_least(count)
    result = nil
    expect { result = yield }.to change { @mget_count }.by_at_least(count)
    result
  end

  def expect_to_use_redis
    expect_mget_count_at_least(1) { yield }
  end

  def expect_not_to_use_redis
    expect_mget_count(0) { yield }
  end

  def expect_to_eq_with_or_without_redis
    expect_to_use_redis do
      expect(yield).to eq(RedisMemo.without_memo { yield })
    end
  end

  it 'requries active record' do
    expect {
      Class.new do
        extend RedisMemo::MemoizeQuery
        memoize_table_column :id
      end
    }.to raise_error(RedisMemo::ArgumentError)

    expect {
      Class.new do
        extend RedisMemo::MemoizeQuery
        memoize_table_column :site_id
      end
    }.to raise_error(RedisMemo::ArgumentError)
  end

  it 'memoizes records' do
    expect {
      model_class.find(1)
    }.to raise_error(ActiveRecord::RecordNotFound)

    expect {
      model_class.find_by_id!(1)
    }.to raise_error(ActiveRecord::RecordNotFound)

    expect_to_eq_with_or_without_redis do
      model_class.find_by_id(1)
    end

    # Create
    record = model_class.create!

    expect_to_eq_with_or_without_redis do
      model_class.find(record.id)
    end
    expect_to_eq_with_or_without_redis do
      model_class.find_by_id!(record.id)
    end
    expect_to_eq_with_or_without_redis do
      model_class.find_by_id(record.id)
    end

    # Update
    record.update(a: 1)
    expect_to_use_redis do
      expect(model_class.find_by_id!(record.id)).to eq(record)
    end

    # Destroy
    record_id = record.id
    record.destroy
    expect_to_eq_with_or_without_redis do
      model_class.find_by_id(record_id)
    end
  end

  context 'when memoizing columns' do
    context 'memoizes method that depends on a single column' do
      let!(:records) { [] }

      before(:each) do
        # Cache old results
        expect(model_class.a_count(2)).to eq(0)
        expect(model_class.a_count(3)).to eq(0)

        # Create
        records << model_class.create!(a: 2)
        expect(model_class.a_count(2)).to eq(1)
        records << model_class.create!(a: 2)
        expect(model_class.a_count(2)).to eq(2)
      end

      it 'recalculates after update' do
        records[0].update!(b: 2)
        expect(model_class.a_count(2)).to eq(2)
        records[1].update!(a: 3)
        expect(model_class.a_count(2)).to eq(1)
        expect(model_class.a_count(3)).to eq(1)

        model_class.update({a: 0, b: 0})
        expect(model_class.a_count(0)).to eq(2)

        model_class.where(a: 0).update(a: 2)
        expect(model_class.a_count(0)).to eq(0)
        expect(model_class.a_count(2)).to eq(2)
      end

      it 'recalculates after destroy' do
        records[0].destroy
        expect(model_class.a_count(2)).to eq(1)

        model_class.create!(a: 2)
        expect(model_class.a_count(2)).to eq(2)
        model_class.where(a: 2).destroy_all
        expect(model_class.a_count(2)).to eq(0)
      end

      it 'recalculates after delete' do
        records[0].delete
        expect(model_class.a_count(2)).to eq(1)

        model_class.create!(a: 2)
        expect(model_class.a_count(2)).to eq(2)
        model_class.where(a: 2).delete_all
        expect(model_class.a_count(2)).to eq(0)

        model_class.create!(a: 2)
        expect(model_class.a_count(2)).to eq(1)
        model_class.delete_all
        expect(model_class.a_count(2)).to eq(0)
      end

      it 'recalculates after import' do
        if model_class.respond_to?(:import)
          records = 5.times.map { model_class.new(a: 2) }
          model_class.import(records)
          expect(model_class.a_count(2)).to eq(7)
        end
      end

      it 'recalculates after update_all' do
        expect(model_class.a_count(0)).to eq(0)

        model_class.where(a: 2).update_all(a: 0)
        expect(model_class.a_count(0)).to eq(2)
        expect(model_class.a_count(2)).to eq(0)
      end

      it 'recalculates after destroy_all' do
        expect(model_class.a_count(0)).to eq(0)

        model_class.where(a: 2).destroy_all
        expect(model_class.a_count(0)).to eq(0)
        expect(model_class.a_count(2)).to eq(0)
      end
    end

    context 'memoizes method that depends on multiple columns' do
      let!(:records) { [] }

      before(:each) do
        # Cache old results
        expect(model_class.a_count(4)).to eq(0)
        expect(model_class.b_count(4)).to eq(0)
        expect(model_class.ab_count(a: 4, b: 0)).to eq(0)
        expect(model_class.ab_count(a: 0, b: 4)).to eq(0)

        records << model_class.create!(a: 4)
        expect(model_class.a_count(4)).to eq(1)
        expect(model_class.ab_count(a: 4, b: 0)).to eq(1)

        records << model_class.create!(b: 4)
        expect(model_class.b_count(4)).to eq(1)
        expect(model_class.ab_count(a: 0, b: 4)).to eq(1)
      end

      it 'recalculates after update' do
        records[1].update!(b: 0, a: 4)
        expect(model_class.a_count(4)).to eq(2)
        expect(model_class.ab_count(a: 4, b: 0)).to eq(2)
        expect(model_class.b_count(0)).to eq(2)
      end

      it 'recalculates after delete' do
        records[0].destroy
        expect(model_class.a_count(0)).to eq(1)
        expect(model_class.b_count(4)).to eq(1)
        expect(model_class.ab_count(a: 4, b: 0)).to eq(0)
        expect(model_class.ab_count(a: 0, b: 4)).to eq(1)
      end
    end
  end

  it 'raises an error if a column does not exist' do
    dependency = RedisMemo::Memoizable::Dependency.new

    expect {
      dependency.instance_exec(nil) do
        depends_on RedisMemoSpecModel, not_a_real_column: '1'
      end
    }.to raise_error(RedisMemo::ArgumentError)
  end

  it 'type casts to string' do
    memos = [
      RedisMemo::MemoizeQuery.create_memo(RedisMemoSpecModel, a: '1', b: '1'),
      RedisMemo::MemoizeQuery.create_memo(RedisMemoSpecModel, a: '1', b: '2'),
      RedisMemo::MemoizeQuery.create_memo(RedisMemoSpecModel, b: 1, a: 1),
    ]
    expect(memos[0].cache_key).to_not eq(memos[1].cache_key)
    expect(memos[0].cache_key).to eq(memos[2].cache_key)


    expect(
      RedisMemo::MemoizeQuery.create_memo(RedisMemoSpecModel, my_enum: 'x').cache_key
    ).to eq(RedisMemo::MemoizeQuery.create_memo(RedisMemoSpecModel, my_enum: 0).cache_key)
  end

  it 'memoizes nested queries' do
    expect_to_use_redis do
      RedisMemoSpecModel.where(id: RedisMemoSpecModel.where(a: [1,2,3])).to_a
    end
  end

  it 'memoizes queries with AND conditions' do
    expect_to_use_redis do
      RedisMemoSpecModel.where(a: 1).where(b: 1).to_a
    end
  end

  it 'memoizes union queries' do
    expect_to_use_redis do
      RedisMemoSpecModel.where(id: 1).or(RedisMemoSpecModel.where(id: 2)).to_a
    end
  end

  it 'does not memoize ordered queries' do
    expect_not_to_use_redis do
      RedisMemoSpecModel.order(:a).take(5)
    end
  end

  it 'does not memoize queries with NOT' do
    expect_not_to_use_redis do
      RedisMemoSpecModel.where(id: RedisMemoSpecModel.where.not(a: 1)).to_a
    end
  end

  it 'does not memoize queries with non-memoized columns' do
    expect_not_to_use_redis do
      RedisMemoSpecModel.where(a: 1, b: 1, not_memoized: 1).to_a
      RedisMemoSpecModel.where(a: 1, not_memoized: 1).to_a
      RedisMemoSpecModel.where(not_memoized: 1).to_a
    end
  end

  it 'invalidates the query result sets when a column has changed' do
    record = RedisMemoSpecModel.create!(a: 1, b: 1)

    expect_to_use_redis do
      # SELECT * FROM model WHERE a = 1
      expect(RedisMemoSpecModel.where(a: 1).to_a).to eq([record])
    end

    expect_to_use_redis do
      # SELECT b FROM model WHERE a = 1
      expect(RedisMemoSpecModel.where(a: 1).select(:b).map(&:b)).to eq([1])
    end

    record.update(b: 2)
    expect_to_use_redis do
      # SELECT * FROM model WHERE a = 1
      expect(RedisMemoSpecModel.where(a: 1).to_a).to eq([record])
    end
    expect_to_use_redis do
      # SELECT b FROM model WHERE a = 1
      expect(RedisMemoSpecModel.where(a: 1).select(:b).map(&:b)).to eq([2])
    end
  end

  it 'only invalidates the affected query result sets' do
    RedisMemo::Cache.with_local_cache do
      record = RedisMemoSpecModel.create!(a: 1, b: 2)

      relation_with_in_clause = RedisMemoSpecModel.where(a: [1, 2])
      relation_with_and_or_clause = RedisMemoSpecModel.where(
        a: RedisMemoSpecModel.where(a: 1).or(RedisMemoSpecModel.where(a: 2)),
        b: [1, 2, 3],
      )

      relations = [
        RedisMemoSpecModel.where(a: 1),
        RedisMemoSpecModel.where(b: 1),
        RedisMemoSpecModel.where(a: 1, b: 1),
        RedisMemoSpecModel.where(a: 2, b: 1),
        relation_with_in_clause,
        relation_with_and_or_clause,
      ]

      relations.each do |relation|
        expect_to_use_redis do
          relation.to_a
        end

        # Using redis-memo local cache
        expect_not_to_use_redis do
          relation.to_a
        end
      end

      # (a: 1, b: 2) -> (a: 2, b: 2)
      record.update(a: 2)

      expect_not_to_use_redis do
        # does not affect WHERE b = 1
        relations[1].reload

        # does not affect WHERE a = 1 AND b = 1
        relations[2].reload

        # does not affect WHERE a = 2 AND b = 1
        relations[3].reload
      end

      expect_to_eq_with_or_without_redis do
        # DOES affect WHERE a = 1
        relations[0].reload
      end

      expect_to_eq_with_or_without_redis do
        # DOES affect WHERE a IN (1, 2)
        relation_with_in_clause.reload
      end

      # DOES affect WHERE a IN (1, 2) AND b IN (1, 2, 3)
      expect_to_eq_with_or_without_redis { relation_with_and_or_clause.reload }
      expect_not_to_use_redis { relation_with_and_or_clause.reload }

      RedisMemoSpecModel.create!(a: 2, b: 3)
      expect_to_eq_with_or_without_redis { relation_with_and_or_clause.reload }
    end
  end
end
