# frozen_string_literal: true

# Redis memo can be flaky due to transient network errors (e.g. Redis connection errors), or when
# used with async handlers. This class allows users to override the default redis-memo behavior
# to be more robust when testing their code that uses redis-memo.
module RedisMemo
  class Testing
    class << self
      attr_accessor :__test_mode
    end

    def self.enable_test_mode(&blk)
      __set_test_mode(true, &blk)
    end

    def self.disable_test_mode(&blk)
      __set_test_mode(false, &blk)
    end

    def self.enabled?
      __test_mode
    end

    def self.__set_test_mode(mode, &blk)
      if blk.nil?
        __test_mode = mode
      else
        prev_mode = __test_mode
        begin
          __test_mode = mode
          yield
        ensure
          __test_mode = prev_mode
        end
      end
    end
  end

  module TestOverrides
    def without_memo?
      if RedisMemo::Testing.enabled? && !RedisMemo::Memoizable::Invalidation.class_variable_get(:@@invalidation_queue).empty?
        return true
      end

      super
    end
  end
  singleton_class.prepend(TestOverrides)
end
