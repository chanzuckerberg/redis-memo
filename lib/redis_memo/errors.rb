# frozen_string_literal: true
module RedisMemo
  class ArgumentError < ::ArgumentError; end
  class RuntimeError < ::RuntimeError; end
  class WithoutMemoization < Exception; end
end
