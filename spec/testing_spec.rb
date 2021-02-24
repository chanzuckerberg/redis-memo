require 'redis_memo/testing'

describe RedisMemo::Testing do
  let(:klass) {
    Class.new do

      def self.test; end

      class << self
        extend RedisMemo::MemoizeMethod
        memoize_method :test
      end
    end
  }

  def expect_no_caching
    expect(RedisMemo::Cache).to_not receive(:read_multi)
    yield
  end

  def expect_caching
    expect(RedisMemo::Cache).to receive(:read_multi).at_least(:once).and_call_original
    yield
  end

  context 'when set globally' do
    RedisMemo::Testing.enable_test_mode

    it 'falls back to non-cached method if invalidation queue is non-empty' do
      expect_caching { klass.test }
      expect_no_caching do
        RedisMemo::Memoizable::Invalidation.class_variable_get(:@@invalidation_queue) << RedisMemo::Memoizable::Invalidation::Task.new('key', 'version', nil)
        klass.test
      end
    end

    it 'disables test mode globally' do
      RedisMemo::Testing.disable_test_mode
      expect_caching do
        RedisMemo::Memoizable::Invalidation.class_variable_get(:@@invalidation_queue) << RedisMemo::Memoizable::Invalidation::Task.new('key', 'version', nil)
        klass.test
      end
    end
  end

  context 'when not set globally' do
    RedisMemo::Memoizable::Invalidation.class_variable_get(:@@invalidation_queue) << RedisMemo::Memoizable::Invalidation::Task.new('key', 'version', nil)
    
    it 'is only enabled for the given block' do
      expect_caching { klass.test }
      expect_no_caching do
        RedisMemo::Testing.enable_test_mode do
          klass.test
        end
      end
    end
  end

end