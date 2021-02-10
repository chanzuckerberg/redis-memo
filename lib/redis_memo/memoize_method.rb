# frozen_string_literal: true
require_relative 'batch'
require_relative 'future'
require_relative 'memoizable'
require_relative 'middleware'
require_relative 'options'

module RedisMemo::MemoizeMethod
  def memoize_method(method_name, method_id: nil, **options, &depends_on)
    method_name_without_memo = :"_redis_memo_#{method_name}_without_memo"
    method_name_with_memo = :"_redis_memo_#{method_name}_with_memo"

    alias_method method_name_without_memo, method_name

    define_method method_name_with_memo do |*args|
      return send(method_name_without_memo, *args) if RedisMemo.without_memo?

      dependent_memos = nil
      if depends_on
        dependency = RedisMemo::MemoizeMethod.get_or_extract_dependencies(self, *args, &depends_on)
        dependent_memos = dependency.memos
      end

      future = RedisMemo::Future.new(
        self,
        case method_id
        when NilClass
          RedisMemo::MemoizeMethod.method_id(self, method_name)
        when String, Symbol
          method_id
        else
          method_id.call(self, *args)
        end,
        args,
        dependent_memos,
        options,
        method_name_without_memo,
      )

      if RedisMemo::Batch.current
        RedisMemo::Batch.current << future
        return future
      end

      future.execute
    rescue RedisMemo::WithoutMemoization
      send(method_name_without_memo, *args)
    end

    alias_method method_name, method_name_with_memo

    @__redis_memo_method_dependencies ||= Hash.new
    @__redis_memo_method_dependencies[method_name] = depends_on

    define_method :dependency_of do |method_name, *method_args|
      method_depends_on = self.class.instance_variable_get(:@__redis_memo_method_dependencies)[method_name]
      unless method_depends_on
        raise(
          RedisMemo::ArgumentError,
          "#{method_name} is not a memoized method"
        )
      end
      RedisMemo::MemoizeMethod.get_or_extract_dependencies(self, *method_args, &method_depends_on)
    end
  end

  def self.method_id(ref, method_name)
    is_class_method = ref.class == Class
    class_name = is_class_method ? ref.name : ref.class.name

    "#{class_name}#{is_class_method ? '::' : '#'}#{method_name}"
  end

  def self.extract_dependencies(ref, *method_args, &depends_on)
    dependency = RedisMemo::Memoizable::Dependency.new

    # Resolve the dependency recursively
    dependency.instance_exec(ref, *method_args, &depends_on)
    dependency
  end

  def self.get_or_extract_dependencies(ref, *method_args, &depends_on)
    if RedisMemo::Cache.local_dependency_cache
      RedisMemo::Cache.local_dependency_cache[ref] ||= {}
      RedisMemo::Cache.local_dependency_cache[ref][depends_on] ||= {}
      RedisMemo::Cache.local_dependency_cache[ref][depends_on][method_args] ||= extract_dependencies(ref, *method_args, &depends_on)
    else
      extract_dependencies(ref, *method_args, &depends_on)
    end
  end

  def self.method_cache_keys(future_contexts)
    memos = Array.new(future_contexts.size)
    future_contexts.each_with_index do |(_, _, dependent_memos), i|
      memos[i] = dependent_memos
    end

    j = 0
    memo_checksums = RedisMemo::Memoizable.checksums(memos.compact)
    method_cache_key_versions = Array.new(future_contexts.size)
    future_contexts.each_with_index do |(method_id, method_args, _), i|
      if memos[i]
        method_cache_key_versions[i] = [method_id, memo_checksums[j]]
        j += 1
      else
        ordered_method_args = method_args.map do |arg|
          arg.is_a?(Hash) ? RedisMemo.deep_sort_hash(arg) : arg
        end

        method_cache_key_versions[i] = [
          method_id,
          RedisMemo.checksum(ordered_method_args.to_json),
        ]
      end
    end

    method_cache_key_versions.map do |method_id, method_cache_key_version|
      # Example:
      #
      #   RedisMemo:MyModel#slow_calculation:<global cache version>:<local
      #   cache version>
      #
      [
        RedisMemo.name,
        method_id,
        RedisMemo::DefaultOptions.global_cache_key_version,
        method_cache_key_version,
      ].join(':')
    end
  rescue RedisMemo::Cache::Rescuable
    nil
  end
end
