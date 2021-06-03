# typed: false
describe RedisMemo::Options do
  context 'cache validation' do
    def allow_rand_return(value)
      allow(Random).to receive(:rand).and_return(value)
    end

    def expect_count(orig_value, updated_value)
      count = 0

      allow(RedisMemo::DefaultOptions).to receive(:cache_out_of_date_handler) do
        proc { count += 1 }
      end

      obj = klass.new
      obj.count = 0

      # cache miss
      expect {
        obj.calc
      }.to change { count }.by(orig_value)

      # cache hit
      expect {
        obj.calc
      }.to change { count }.by(updated_value)
    end

    def expect_cache_validation
      # With cache validation, the count will change by 1
      expect_count(0, 1)
    end

    def expect_no_cache_validation
      # Without cache validation, the count will not change
      expect_count(0, 0)
    end

    context 'with only global cache validation sample percentage' do
      def set_cache_validation_sample_percentage(value)
        allow(RedisMemo::DefaultOptions).to receive(:cache_validation_sample_percentage).and_return(value)
      end

      let!(:klass) do
        Class.new do
          extend RedisMemo::MemoizeMethod
          attr_accessor :count

          def calc
            @count += 1
          end

          memoize_method :calc
        end
      end

      context 'cache validation sample percentage is 100' do
        it 'validates the cache result' do
          set_cache_validation_sample_percentage(100)

          expect_cache_validation
        end
      end

      context 'cache validation sample percentage is < 100' do
        it 'validates the cache result if generating a lower random value' do
          cache_validation_sample_percentage = 60
          rand_value = cache_validation_sample_percentage - 10

          set_cache_validation_sample_percentage(cache_validation_sample_percentage)
          allow_rand_return(rand_value)

          expect_cache_validation
        end

        it 'does not validate the cache result if generating a higher random value' do
          cache_validation_sample_percentage = 60
          rand_value = cache_validation_sample_percentage + 10

          set_cache_validation_sample_percentage(cache_validation_sample_percentage)
          allow_rand_return(rand_value)

          expect_no_cache_validation
        end

        it 'does not validate the cache result if cache alidation sample percentage is 0' do
          set_cache_validation_sample_percentage(0)

          expect_no_cache_validation
        end
      end
    end

    context 'with inline cache validation sample percentage' do
      def klass_with_cache_validation_sample_percentage(value)
        Class.new do
          extend RedisMemo::MemoizeMethod

          attr_accessor :count

          def calc
            @count += 1
          end

          memoize_method :calc, cache_validation_sample_percentage: value
        end
      end

      context 'cache validation sample percentage is 100' do
        let!(:klass) { klass_with_cache_validation_sample_percentage(100) }

        it 'validates the results' do
          expect_any_instance_of(RedisMemo::Future).to receive(:validate_cache_result).and_call_original
          expect_cache_validation
        end
      end

      context 'cache validation sample percentage is < 100' do
        let!(:cache_validation_sample_percentage) { 60 }
        let!(:klass) { klass_with_cache_validation_sample_percentage(cache_validation_sample_percentage) }

        it 'validates the cache result if generating a lower random value' do
          rand_value = cache_validation_sample_percentage - 10

          allow_rand_return(rand_value)

          expect_any_instance_of(RedisMemo::Future).to receive(:validate_cache_result).and_call_original
          expect_cache_validation
        end

        it 'does not validate the cache result if generating a higher random value' do
          rand_value = cache_validation_sample_percentage + 10

          allow_rand_return(rand_value)

          expect_any_instance_of(RedisMemo::Future).to receive(:validate_cache_result).and_call_original
          expect_no_cache_validation
        end
      end

      context 'cache validation sample percentage is 0' do
        let!(:klass) { klass_with_cache_validation_sample_percentage(0) }
        it 'does not validate the cache result' do
          expect_any_instance_of(RedisMemo::Future).to receive(:validate_cache_result).and_call_original
          expect_no_cache_validation
        end
      end
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
