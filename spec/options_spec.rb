# typed: false
describe RedisMemo::Options do
  context 'cache validation' do
    it 'validates the cache result' do
      allow(RedisMemo::DefaultOptions).to receive(:cache_validation_sampler) do
        proc { true }
      end

      count = 0

      allow(RedisMemo::DefaultOptions).to receive(:cache_out_of_date_handler) do
        proc { count += 1 }
      end

      klass = Class.new do
        extend RedisMemo::MemoizeMethod
        attr_accessor :count

        def calc
          @count += 1
        end

        memoize_method :calc
      end

      obj = klass.new
      obj.count = 0

      # cache miss
      expect {
        obj.calc
      }.to change { count }.by(0)

      # cache hit
      expect {
        obj.calc
      }.to change { count }.by(1)
    end
  end

  context 'disable caching options' do
    # Reset options to default values after each test
    before(:each) do
      stub_const('RedisMemo::DefaultOptions', RedisMemo::Options.new)
    end

    def expect_no_caching
      expect(RedisMemo::Cache).to_not receive(:read_multi)
      yield
    end

    it 'disables caching when the disable option is set' do
      klass = Class.new do
        extend RedisMemo::MemoizeMethod
        attr_accessor :count

        def calc
          @count += 1
        end
      end

      RedisMemo::DefaultOptions.disable_all = true
      obj = klass.new
      obj.count = 0

      expect {
        5.times { expect_no_caching { obj.calc } }
      }.to change { obj.count }.by(5)
    end

    context 'query caching' do
      before(:all) do
        ActiveRecord::Base.connection.execute 'drop table if exists test_models'
        ActiveRecord::Base.connection.create_table :test_models do |t|
          t.integer 'a', default: 0
        end
      end

      after(:all) do
        ActiveRecord::Base.connection.execute 'drop table if exists test_models'
      end

      # Set and unset the TestModel constant to reload the model definition
      let(:test_model_klass) { Class.new(ActiveRecord::Base) { extend RedisMemo::MemoizeQuery } }

      before(:each) do
        Object.const_set('TestModel', test_model_klass)
      end

      after(:each) do
        Object.__send__(:remove_const, 'TestModel')
      end

      it 'disables query caching on tables that are disabled' do
        # Reload the model and call memoize_table_column after options are set
        RedisMemo::DefaultOptions.disable_model(TestModel)
        TestModel.memoize_table_column :id, editable: false

        test_model = TestModel.create!

        expect_no_caching do
          # Check that query caching is disabled on the model
          TestModel.find(test_model.id)

          # Check that invalidation model callbacks are disabled on update and destroy
          expect(RedisMemo::MemoizeQuery).not_to receive(:invalidate)
          test_model.update!(a: 1)
          test_model.destroy!
        end
      end
    end
  end
end
