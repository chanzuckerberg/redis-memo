# typed: true

module RedisMemo
  extend RedisMemo::MemoizeMethod
  extend RedisMemo::MemoizeRecords

  DefaultOptions = RedisMemo::Options.new

  def self.configure(&blk)
    blk.call(DefaultOptions)
  end

  def self.batch(&blk)
    RedisMemo::Batch.open
    blk.call
    RedisMemo::Batch.execute
  ensure
    RedisMemo::Batch.close
  end

  def self.checksum(serialized)
    Digest::SHA1.base64digest(serialized)
  end

  def self.deep_sort_hash(orig_hash)
    {}.tap do |new_hash|
      orig_hash.sort.each do |k, v|
        new_hash[k] = v.is_a?(Hash) ? deep_sort_hash(v) : v
      end
    end
  end

  THREAD_KEY_WITHOUT_MEMO = :__redis_memo_without_memo__

  def self.without_memo?
    Thread.current[THREAD_KEY_WITHOUT_MEMO] == true
  end

  def self.without_memo
    prev_value = Thread.current[THREAD_KEY_WITHOUT_MEMO]
    Thread.current[THREAD_KEY_WITHOUT_MEMO] = true
    yield
  ensure
    Thread.current[THREAD_KEY_WITHOUT_MEMO] = prev_value
  end

  class ArgumentError < ::ArgumentError; end
  class RuntimeError < ::RuntimeError; end
end
