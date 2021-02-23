require 'activerecord-import'

describe RedisMemo::MemoizeQuery do
  class Site < ActiveRecord::Base
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

  class User < ActiveRecord::Base
    extend RedisMemo::MemoizeQuery
  end

  class Teacher < User
    has_many :teacher_sites
    has_many :sites, through: :teacher_sites
  end

  class TeacherSite < ActiveRecord::Base
    extend RedisMemo::MemoizeQuery

    belongs_to :teacher
    belongs_to :site
  end

  before(:all) do
    # Drop the table in case the test case was aborted
    ActiveRecord::Base.connection.execute 'drop table if exists sites'
    ActiveRecord::Base.connection.create_table :sites do |t|
      t.integer 'a', default: 0
      t.integer 'b', default: 0
      t.integer 'not_memoized', default: 0
      t.integer 'my_enum', default: 0
    end
    Site.memoize_table_column :id, editable: false
    Site.memoize_table_column :a
    Site.memoize_table_column :b
    Site.memoize_table_column :my_enum
    Site.memoize_table_column :a, :b

    ActiveRecord::Base.connection.execute 'drop table if exists users'
    ActiveRecord::Base.connection.create_table :users do |t|
      t.string 'type'

      t.integer 'a', default: 0
      t.integer 'b', default: 0
    end
    User.memoize_table_column :id, editable: false
    User.memoize_table_column :id, :type, editable: false

    ActiveRecord::Base.connection.execute 'drop table if exists teacher_sites'
    ActiveRecord::Base.connection.create_table :teacher_sites do |t|
      t.integer 'site_id'
      t.integer 'teacher_id'
    end
    TeacherSite.memoize_table_column :site_id
    TeacherSite.memoize_table_column :teacher_id
    TeacherSite.memoize_table_column :site_id, :teacher_id
  end

  after(:all) do
    # Clean up
    ActiveRecord::Base.connection.execute 'drop table if exists sites'
    ActiveRecord::Base.connection.execute 'drop table if exists users'
    ActiveRecord::Base.connection.execute 'drop table if exists teacher_sites'
  end

  let!(:redis) { RedisMemo::Cache.redis }

  before(:each) do
    @mget_count = 0
    allow(redis).to receive(:mget).and_wrap_original do |method, *args|
      @mget_count += 1
      method.call(*args)
    end
    Site.spec_context = self
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
      Teacher.find(1)
    }.to raise_error(ActiveRecord::RecordNotFound)

    expect {
      Teacher.find_by_id!(1)
    }.to raise_error(ActiveRecord::RecordNotFound)

    expect_to_eq_with_or_without_redis do
      Teacher.find_by_id(1)
    end

    # Create
    record = Teacher.create!

    expect_to_eq_with_or_without_redis do
      Teacher.find(record.id)
    end
    expect_to_eq_with_or_without_redis do
      Teacher.find_by_id!(record.id)
    end
    expect_to_eq_with_or_without_redis do
      Teacher.find_by_id(record.id)
    end

    expect(User.find_by_id(record.id)).to eq(Teacher.find_by_id(record.id))

    # Update
    record.update(a: 1)
    expect_to_use_redis do
      expect(Teacher.find_by_id!(record.id)).to eq(record)
    end

    # Destroy
    record_id = record.id
    record.destroy
    expect_to_eq_with_or_without_redis do
      Teacher.find_by_id(record_id)
    end
  end

  context 'when memoizing columns' do
    context 'memoizes method that depends on a single column' do
      let!(:records) { [] }

      before(:each) do
        # Cache old results
        expect(Site.a_count(2)).to eq(0)
        expect(Site.a_count(3)).to eq(0)

        # Create
        records << Site.create!(a: 2)
        expect(Site.a_count(2)).to eq(1)
        records << Site.create!(a: 2)
        expect(Site.a_count(2)).to eq(2)
      end

      it 'recalculates after update' do
        records[0].update!(b: 2)
        expect(Site.a_count(2)).to eq(2)
        records[1].update!(a: 3)
        expect(Site.a_count(2)).to eq(1)
        expect(Site.a_count(3)).to eq(1)

        Site.update({a: 0, b: 0})
        expect(Site.a_count(0)).to eq(2)

        Site.where(a: 0).update(a: 2)
        expect(Site.a_count(0)).to eq(0)
        expect(Site.a_count(2)).to eq(2)
      end

      it 'recalculates after destroy' do
        records[0].destroy
        expect(Site.a_count(2)).to eq(1)

        Site.create!(a: 2)
        expect(Site.a_count(2)).to eq(2)
        Site.where(a: 2).destroy_all
        expect(Site.a_count(2)).to eq(0)
      end

      it 'recalculates after delete' do
        records[0].delete
        expect(Site.a_count(2)).to eq(1)

        Site.create!(a: 2)
        expect(Site.a_count(2)).to eq(2)
        Site.where(a: 2).delete_all
        expect(Site.a_count(2)).to eq(0)

        Site.create!(a: 2)
        expect(Site.a_count(2)).to eq(1)
        Site.delete_all
        expect(Site.a_count(2)).to eq(0)
      end

      # Test cases for activerecord >= 6
      if Site.respond_to?(:insert!)
        it 'recalculates after insert' do
          RedisMemo::Cache.with_local_cache do
            site = Site.create!(a: 0)
            expect_to_eq_with_or_without_redis do
              Site.find(site.id)
            end

            records = 5.times.map { {a: 2} }
            Site.insert_all!(records)
            expect(Site.a_count(2)).to eq(7)

            Site.insert!(records.last)
            expect(Site.a_count(2)).to eq(8)

            Site.insert!({a: 0})
            # site(a: 0) is not affected by the imports
            expect_not_to_use_redis do
              5.times { Site.find(site.id) }
            end
          end
        end
      end

      if Site.respond_to?(:upsert_all)
        it 'recalculates after upsert' do
          RedisMemo::Cache.with_local_cache do
            site = Site.create!(a: 0)
            expect_to_eq_with_or_without_redis do
              Site.find(site.id)
            end

            records = 5.times.map { {a: 2} }
            Site.upsert_all(records)
            expect(Site.a_count(2)).to eq(7)

            Site.upsert(records.last)
            expect(Site.a_count(2)).to eq(8)

            Site.upsert({a: 0})
            # site(a: 0) is not affected by the imports
            expect_not_to_use_redis do
              5.times { Site.find(site.id) }
            end
          end
        end
      end

      it 'recalculates after import' do
        RedisMemo::Cache.with_local_cache do
          site = Site.create!(a: 0)
          expect_to_eq_with_or_without_redis do
            Site.find(site.id)
          end

          records = 5.times.map { Site.new(a: 2) }
          Site.import(records)
          expect(Site.a_count(2)).to eq(7)

          records.each do |record|
            record.a = 3
          end
          Site.import(records, on_duplicate_key_update: [:a])
          expect(Site.a_count(3)).to eq(5)

          records.each do |record|
            record.a = 4
          end
          Site.import(records, on_duplicate_key_update: {conflict_target: [:id], columns: [:a]})
          expect(Site.a_count(4)).to eq(5)

          Site.import([])
          Site.import([], on_duplicate_key_update: [:a])
          # site(a: 0) is not affected by the imports
          expect_not_to_use_redis do
            5.times { Site.find(site.id) }
          end
        end
      end

      it 'recalculates after update_all' do
        expect(Site.a_count(0)).to eq(0)

        Site.where(a: 2).update_all(a: 0)
        expect(Site.a_count(0)).to eq(2)
        expect(Site.a_count(2)).to eq(0)
      end

      it 'recalculates after destroy_all' do
        expect(Site.a_count(0)).to eq(0)

        Site.where(a: 2).destroy_all
        expect(Site.a_count(0)).to eq(0)
        expect(Site.a_count(2)).to eq(0)
      end
    end

    context 'memoizes method that depends on multiple columns' do
      let!(:records) { [] }

      before(:each) do
        # Cache old results
        expect(Site.a_count(4)).to eq(0)
        expect(Site.b_count(4)).to eq(0)
        expect(Site.ab_count(a: 4, b: 0)).to eq(0)
        expect(Site.ab_count(a: 0, b: 4)).to eq(0)

        records << Site.create!(a: 4)
        expect(Site.a_count(4)).to eq(1)
        expect(Site.ab_count(a: 4, b: 0)).to eq(1)

        records << Site.create!(b: 4)
        expect(Site.b_count(4)).to eq(1)
        expect(Site.ab_count(a: 0, b: 4)).to eq(1)
      end

      it 'recalculates after update' do
        records[1].update!(b: 0, a: 4)
        expect(Site.a_count(4)).to eq(2)
        expect(Site.ab_count(a: 4, b: 0)).to eq(2)
        expect(Site.b_count(0)).to eq(2)
      end

      it 'recalculates after delete' do
        records[0].destroy
        expect(Site.a_count(0)).to eq(1)
        expect(Site.b_count(4)).to eq(1)
        expect(Site.ab_count(a: 4, b: 0)).to eq(0)
        expect(Site.ab_count(a: 0, b: 4)).to eq(1)
      end
    end
  end

  it 'raises an error if a column does not exist' do
    dependency = RedisMemo::Memoizable::Dependency.new

    expect {
      dependency.instance_exec(nil) do
        depends_on Site, not_a_real_column: '1'
      end
    }.to raise_error(RedisMemo::ArgumentError)
  end

  it 'type casts to string' do
    memos = [
      RedisMemo::MemoizeQuery.create_memo(Site, a: '1', b: '1'),
      RedisMemo::MemoizeQuery.create_memo(Site, a: '1', b: '2'),
      RedisMemo::MemoizeQuery.create_memo(Site, b: 1, a: 1),
    ]
    expect(memos[0].cache_key).to_not eq(memos[1].cache_key)
    expect(memos[0].cache_key).to eq(memos[2].cache_key)


    expect(
      RedisMemo::MemoizeQuery.create_memo(Site, my_enum: 'x').cache_key
    ).to eq(RedisMemo::MemoizeQuery.create_memo(Site, my_enum: 0).cache_key)
  end

  it 'memoizes nested queries' do
    expect_to_use_redis do
      Site.where(id: Site.where(a: [1,2,3])).to_a
    end
  end

  it 'memoizes queries with AND conditions' do
    expect_to_use_redis do
      Site.where(a: 1).where(b: 1).to_a
    end
  end

  it 'does not memoize queries with JOIN conditions' do
    teacher = Teacher.create!
    expect_not_to_use_redis do
      teacher.sites.where(a: 1).to_a
    end
  end

  it 'memoizes union queries' do
    expect_to_use_redis do
      Site.where(id: 1).or(Site.where(id: 2)).to_a
    end
  end

  it 'does not memoize unbound queries' do
    expect_not_to_use_redis do
      Site.limit(5).to_a
    end

    teacher = Teacher.create!
    expect_not_to_use_redis do
      teacher.sites.to_a
    end
  end

  it 'does not memoize ordered queries' do
    expect_not_to_use_redis do
      Site.order(:a).take(5)
    end
  end

  it 'does not memoize queries with NOT' do
    expect_not_to_use_redis do
      Site.where(id: Site.where.not(a: 1)).to_a
    end
  end

  it 'does not memoize queries with non-memoized columns' do
    expect_not_to_use_redis do
      Site.where(a: 1, b: 1, not_memoized: 1).to_a
      Site.where(a: 1, not_memoized: 1).to_a
      Site.where(not_memoized: 1).to_a
    end
  end

  it 'invalidates the query result sets when a column has changed' do
    record = Site.create!(a: 1, b: 1)

    expect_to_use_redis do
      # SELECT * FROM model WHERE a = 1
      expect(Site.where(a: 1).to_a).to eq([record])
    end

    expect_to_use_redis do
      # SELECT b FROM model WHERE a = 1
      expect(Site.where(a: 1).select(:b).map(&:b)).to eq([1])
    end

    record.update(b: 2)
    expect_to_use_redis do
      # SELECT * FROM model WHERE a = 1
      expect(Site.where(a: 1).to_a).to eq([record])
    end
    expect_to_use_redis do
      # SELECT b FROM model WHERE a = 1
      expect(Site.where(a: 1).select(:b).map(&:b)).to eq([2])
    end
  end

  it 'only invalidates the affected query result sets' do
    RedisMemo::Cache.with_local_cache do
      record = Site.create!(a: 1, b: 2)

      relation_with_in_clause = Site.where(a: [1, 2])
      relation_with_and_or_clause = Site.where(
        a: Site.where(a: 1).or(Site.where(a: 2)),
        b: [1, 2, 3],
      )

      relations = [
        Site.where(a: 1),
        Site.where(b: 1),
        Site.where(a: 1, b: 1),
        Site.where(a: 2, b: 1),
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

      Site.create!(a: 2, b: 3)
      expect_to_eq_with_or_without_redis { relation_with_and_or_clause.reload }
    end
  end
end
