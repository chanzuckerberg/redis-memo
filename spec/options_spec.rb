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
end
