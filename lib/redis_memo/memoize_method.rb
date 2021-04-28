# frozen_string_literal: true

require_relative 'batch'
require_relative 'future'
require_relative 'memoizable'
require_relative 'middleware'
require_relative 'options'
require_relative 'util'

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
        raise RedisMemo::ArgumentError.new("#{method_name} is not a memoized method")
      end

      RedisMemo::MemoizeMethod.get_or_extract_dependencies(self, *method_args, &method_depends_on)
    end
  end

  class << self
    def method_id(ref, method_name)
      is_class_method = ref.class == Class
      class_name = is_class_method ? ref.name : ref.class.name

      "#{class_name}#{is_class_method ? '::' : '#'}#{method_name}"
    end

    def get_or_extract_dependencies(ref, *method_args, &depends_on)
      if RedisMemo::Cache.local_dependency_cache
        RedisMemo::Cache.local_dependency_cache[ref.class] ||= {}
        RedisMemo::Cache.local_dependency_cache[ref.class][depends_on] ||= {}
        named_args = exclude_anonymous_args(depends_on, ref, method_args)
        RedisMemo::Cache.local_dependency_cache[ref.class][depends_on][named_args] ||= extract_dependencies(ref, *method_args, &depends_on)
      else
        extract_dependencies(ref, *method_args, &depends_on)
      end
    end

    def method_cache_keys(future_contexts)
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
            arg.is_a?(Hash) ? RedisMemo::Util.deep_sort_hash(arg) : arg
          end

          method_cache_key_versions[i] = [
            method_id,
            RedisMemo::Util.checksum(ordered_method_args.to_json),
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

    private

    def extract_dependencies(ref, *method_args, &depends_on)
      dependency = RedisMemo::Memoizable::Dependency.new

      # Resolve the dependency recursively
      dependency.instance_exec(ref, *method_args, &depends_on)
      dependency
    end

    # We only look at named method parameters in the dependency block in order
    # to define its dependent memos and ignore anonymous parameters, following
    # the convention that nil or :_ is an anonymous parameter.
    #
    # Example:
    # ```
    #    def method(param1, param2)
    #    end
    #
    #    memoize_method :method do |_, _, param2|`
    #      depends_on RedisMemo::Memoizable.new(param2: param2)
    #    end
    # ```
    #  `exclude_anonymous_args(depends_on, ref, [1, 2])` returns [2]
    def exclude_anonymous_args(depends_on, ref, args)
      return [] if depends_on.parameters.empty? || args.empty?

      positional_args = []
      kwargs = {}
      depends_on_args = [ref] + args
      options = depends_on_args.extract_options!

      # Keep track of the splat start index, and the number of positional args before and after the splat,
      # so we can map which args belong to positional args and which args belong to the splat.
      named_splat = false
      splat_index = nil
      num_positional_args_after_splat = 0
      num_positional_args_before_splat = 0

      depends_on.parameters.each_with_index do |param, i|
        # Defined by https://github.com/ruby/ruby/blob/22b8ddfd1049c3fd1e368684c4fd03bceb041b3a/proc.c#L3048-L3059
        case param.first
        when :opt, :req
          if splat_index
            num_positional_args_after_splat += 1
          else
            num_positional_args_before_splat += 1
          end
        when :rest
          named_splat = is_named?(param)
          splat_index = i
        when :key, :keyreq
          kwargs[param.last] = options[param.last] if is_named?(param)
        when :keyrest
          kwargs.merge!(options) if is_named?(param)
        else
          raise RedisMemo::ArgumentError.new("#{param.first} argument isn't supported in the dependency block")
        end
      end

      # Determine the named positional and splat arguments after we know the # of pos. arguments before and after splat
      after_splat_index = depends_on_args.size - num_positional_args_after_splat
      depends_on_args.each_with_index do |arg, i|
        # if the index is within the splat
        if i >= num_positional_args_before_splat && i < after_splat_index
          positional_args << arg if named_splat
        else
          j = i < num_positional_args_before_splat ? i : i - (after_splat_index - splat_index) - 1
          positional_args << arg if is_named?(depends_on.parameters[j])
        end
      end

      if !kwargs.empty?
        positional_args + [kwargs]
      elsif named_splat && !options.empty?
        positional_args + [options]
      else
        positional_args
      end
    end

    def is_named?(param)
      param.size == 2 && param.last != :_
    end
  end
end
