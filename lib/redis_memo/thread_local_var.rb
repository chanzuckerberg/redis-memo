# frozen_string_literal: true

module RedisMemo::ThreadLocalVar
  def self.define(var_name) # :nodoc:
    thread_key = :"__redis_memo_#{var_name}__"
    const_set(var_name.to_s.upcase, thread_key)

    define_singleton_method var_name do
      Thread.current[thread_key]
    end

    define_singleton_method "#{var_name}=" do |var_val|
      Thread.current[thread_key] = var_val
    end
  end
end
