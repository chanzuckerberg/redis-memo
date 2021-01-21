# typed: false
module RedisMemo::MemoizeMethod
  def memoize_method(method_name, **options, &depends_on)
    method_name_without_memo = :"_redis_memo_#{method_name}_without_memo"
    method_name_with_memo = :"_redis_memo_#{method_name}_with_memo"

    alias_method method_name_without_memo, method_name

    define_method method_name_with_memo do |*args|
      return send(method_name_without_memo, *args) if RedisMemo.without_memo?

      future = RedisMemo::Future.new(
        self,
        RedisMemo::MemoizeMethod.method_id(self, method_name),
        args,
        depends_on,
        options,
        method_name_without_memo,
      )

      if RedisMemo::Batch.current
        RedisMemo::Batch.current << future
        return future
      end

      future.execute
    end

    alias_method method_name, method_name_with_memo
  end

  def self.method_id(ref, method_name)
    is_class_method = ref.class == Class
    class_name = is_class_method ? ref.name : ref.class.name

    "#{class_name}#{is_class_method ? '::' : '#'}#{method_name}"
  end

  def self.method_cache_keys(future_contexts)
    memos = Array.new(future_contexts.size)
    future_contexts.each_with_index do |(ref, _, method_args, depends_on), i|
      if depends_on
        dependency = RedisMemo::Memoizable::Dependency.new

        # Resolve the dependency recursively
        dependency.instance_exec(ref, *method_args, &depends_on)

        memos[i] = dependency.memos
      end
    end

    j = 0
    memo_checksums = RedisMemo::Memoizable.checksums(memos.compact)
    method_cache_key_versions = Array.new(future_contexts.size)
    future_contexts.each_with_index do |(_, method_id, method_args, _), i|
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
