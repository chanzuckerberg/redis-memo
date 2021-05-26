# frozen_string_literal: true

require_relative 'cache'
require_relative 'tracer'

class RedisMemo::Future
  attr_writer :method_cache_key

  def initialize(
    ref,
    method_id,
    method_args,
    dependent_memos,
    cache_options,
    method_name_without_memoization
  )
    @ref = ref
    @method_id = method_id
    @method_args = method_args
    @dependent_memos = dependent_memos
    @cache_options = cache_options
    @method_name_without_memoization = method_name_without_memoization
    @method_cache_key = nil
    @cache_hit = false
    @cached_result = nil
    @computed_cached_result = false
    @fresh_result = nil
    @computed_fresh_result = false
  end

  def context
    [@method_id, @method_args, @dependent_memos]
  end

  def method_cache_key
    @method_cache_key ||=
      RedisMemo::MemoizeMethod.__send__(:method_cache_keys, [context])&.first || ''
  end

  def execute(cached_results = nil)
    if RedisMemo::Batch.current
      raise RedisMemo::RuntimeError.new('Cannot execute future when a batch is still open')
    end

    if cache_hit?(cached_results)
      validate_cache_result =
        RedisMemo::DefaultOptions.cache_validation_sampler&.call(@method_id)

      if validate_cache_result && cached_result != fresh_result
        RedisMemo::DefaultOptions.cache_out_of_date_handler&.call(
          @ref,
          @method_id,
          @method_args,
          cached_result,
          fresh_result,
        )
        return fresh_result
      end

      return cached_result
    end

    fresh_result
  end

  def result
    unless @computed_cached_result
      raise RedisMemo::RuntimeError.new('Future has not been executed')
    end

    @fresh_result || @cached_result
  end

  private

  def cache_hit?(cached_results = nil)
    cached_result(cached_results)

    @cache_hit
  end

  def cached_result(cached_results = nil)
    return @cached_result if @computed_cached_result

    @cache_hit = false
    RedisMemo::Tracer.trace('redis_memo.cache.read', @method_id) do
      # Calculate the method_cache_key now, or use the method_cache_key obtained
      # from batching previously
      if !method_cache_key.empty?
        cached_results ||= RedisMemo::Cache.read_multi(method_cache_key)
        @cache_hit = cached_results.include?(method_cache_key)
        @cached_result = cached_results[method_cache_key]
      end
      RedisMemo::Tracer.set_tag(cache_hit: @cache_hit)
    end

    @computed_cached_result = true
    @cached_result
  end

  def fresh_result
    return @fresh_result if @computed_fresh_result

    RedisMemo::Tracer.trace('redis_memo.cache.write', @method_id) do
      # cache miss
      @fresh_result = @ref.__send__(@method_name_without_memoization, *@method_args)
      if @cache_options.include?(:expires_in) && @cache_options[:expires_in].respond_to?(:call)
        @cache_options[:expires_in] = @cache_options[:expires_in].call(@fresh_result)
      end

      if !method_cache_key.empty? && (
          # Write back fresh result if cache miss
          !@cache_hit || (
            # or cached result is out of date (sampled to validate the cache
            # result)
            @cache_hit && @cached_result != @fresh_result
          )
        )
        RedisMemo::Cache.write(method_cache_key, @fresh_result, **@cache_options)
      end
    end

    @computed_fresh_result = true
    @fresh_result
  end
end
