# frozen_string_literal: true

#
# Automatically invalidate memoizable when modifying ActiveRecords objects.
# You still need to invalidate memos when you are using SQL queries to perform
# update / delete (does not trigger record callbacks)
#
class RedisMemo::MemoizeQuery::Invalidation
  def self.install(model_class)
    var_name = :@@__redis_memo_memoize_query_invalidation_installed__
    return if model_class.class_variable_defined?(var_name)

    model_class.class_eval do
      # A memory-persistent memoizable used for invalidating all queries of a
      # particular model
      def self.redis_memo_class_memoizable
        @redis_memo_class_memoizable ||= RedisMemo::MemoizeQuery.create_memo(self)
      end

      %i[delete decrement! increment!].each do |method_name|
        alias_method :"without_redis_memo_invalidation_#{method_name}", method_name

        define_method method_name do |*args|
          result = __send__(:"without_redis_memo_invalidation_#{method_name}", *args)

          RedisMemo::MemoizeQuery.invalidate(self)

          result
        end
        ruby2_keywords method_name
      end
    end

    # Methods that won't trigger model callbacks
    # https://guides.rubyonrails.org/active_record_callbacks.html#skipping-callbacks
    %i[
      decrement_counter
      delete_all delete_by
      increment_counter
      touch_all
      update_column update_columns update_all update_counters
    ].each do |method_name|
      # Example: Model.update_all
      rewrite_default_method(
        model_class,
        model_class,
        method_name,
        class_method: true,
      )

      # Example: Model.where(...).update_all
      rewrite_default_method(
        model_class,
        model_class.const_get(:ActiveRecord_Relation),
        method_name,
        class_method: false,
      )
    end

    %i[
      insert insert! insert_all insert_all!
    ].each do |method_name|
      rewrite_insert_method(
        model_class,
        method_name,
      )
    end

    %i[
      upsert upsert_all
    ].each do |method_name|
      rewrite_upsert_method(
        model_class,
        method_name,
      )
    end

    %i[
      import import!
    ].each do |method_name|
      rewrite_import_method(
        model_class,
        method_name,
      )
    end

    model_class.class_variable_set(var_name, true)
  end

  def self.invalidate_new_records(model_class, &blk)
    current_id = model_class.maximum(model_class.primary_key)
    result = blk.call
    records = select_by_new_ids(model_class, current_id)
    RedisMemo::MemoizeQuery.invalidate(*records) unless records.empty?
    result
  end

  def self.invalidate_records_by_conflict_target(model_class, records:, conflict_target: nil, &blk)
    if conflict_target.nil?
      # When the conflict_target is not set, we are basically inserting new
      # records since duplicate rows are simply skipped
      return invalidate_new_records(model_class, &blk)
    end

    relation = build_relation_by_conflict_target(model_class, records, conflict_target)
    # Invalidate records before updating
    records = select_by_conflict_target_relation(model_class, relation)
    RedisMemo::MemoizeQuery.invalidate(*records) unless records.empty?

    # Perform updating
    result = blk.call

    # Invalidate records after updating
    records = select_by_conflict_target_relation(model_class, relation)
    RedisMemo::MemoizeQuery.invalidate(*records) unless records.empty?

    result
  end

  #
  # There’s no good way to perform fine-grind cache invalidation when
  # operations are bulk update operations such as update_all, and delete_all
  # witout fetching additional data from the database, which might lead to
  # performance degradation. Thus, by default, we simply invalidate all
  # existing cached records after each bulk_updates.
  #
  def self.rewrite_default_method(model_class, klass, method_name, class_method:)
    methods = class_method ? :methods : :instance_methods
    return unless klass.__send__(methods).include?(method_name)

    klass = klass.singleton_class if class_method
    klass.class_eval do
      alias_method :"#{method_name}_without_redis_memo_invalidation", method_name

      define_method method_name do |*args|
        result = __send__(:"#{method_name}_without_redis_memo_invalidation", *args)
        RedisMemo::MemoizeQuery.invalidate_all(model_class)
        result
      end
      ruby2_keywords method_name
    end
  end

  def self.rewrite_insert_method(model_class, method_name)
    return unless model_class.respond_to?(method_name)

    model_class.singleton_class.class_eval do
      alias_method :"#{method_name}_without_redis_memo_invalidation", method_name

      define_method method_name do |*args, &blk|
        RedisMemo::MemoizeQuery::Invalidation.invalidate_new_records(model_class) do
          __send__(:"#{method_name}_without_redis_memo_invalidation", *args, &blk)
        end
      end
      ruby2_keywords method_name
    end
  end

  def self.rewrite_upsert_method(model_class, method_name)
    return unless model_class.respond_to?(method_name)

    model_class.singleton_class.class_eval do
      alias_method :"#{method_name}_without_redis_memo_invalidation", method_name

      define_method method_name do |attributes, unique_by: nil, **kwargs, &blk|
        RedisMemo::MemoizeQuery::Invalidation.invalidate_records_by_conflict_target(
          model_class,
          records: nil, # not used
          # upsert does not support on_duplicate_key_update yet at activerecord
          # HEAD (6.1.3)
          conflict_target: nil,
        ) do
          __send__(
            :"#{method_name}_without_redis_memo_invalidation",
            attributes,
            unique_by: unique_by,
            **kwargs,
            &blk
          )
        end
      end
    end
  end

  def self.rewrite_import_method(model_class, method_name)
    return unless model_class.respond_to?(method_name)

    model_class.singleton_class.class_eval do
      alias_method :"#{method_name}_without_redis_memo_invalidation", method_name

      # For the args format, see
      # https://github.com/zdennis/activerecord-import/blob/master/lib/activerecord-import/import.rb#L128
      define_method method_name do |*args, &blk|
        options = args.last.is_a?(Hash) ? args.last : {}
        records = args[args.last.is_a?(Hash) ? -2 : -1]
        on_duplicate_key_update = options[:on_duplicate_key_update]
        conflict_target =
          case on_duplicate_key_update
          when Hash
            # The conflict_target option is only supported in PostgreSQL. In
            # MySQL, the primary_key is used as the conflict_target
            on_duplicate_key_update[:conflict_target] || [model_class.primary_key.to_sym]
          when Array
            # The default conflict_target is just the primary_key
            [model_class.primary_key.to_sym]
          else
            # Ignore duplicate rows
            nil
          end

        if conflict_target && records.last.is_a?(Hash)
          records.map! { |hash| model_class.new(hash) }
        end

        RedisMemo::MemoizeQuery::Invalidation.invalidate_records_by_conflict_target(
          model_class,
          records: records,
          conflict_target: conflict_target,
        ) do
          __send__(:"#{method_name}_without_redis_memo_invalidation", *args, &blk)
        end
      end
      ruby2_keywords method_name
    end
  end

  def self.build_relation_by_conflict_target(model_class, records, conflict_target)
    or_chain = nil

    records.each do |record|
      conditions = {}
      conflict_target.each do |column|
        conditions[column] = record.__send__(column)
      end
      if or_chain
        or_chain = or_chain.or(model_class.where(conditions))
      else
        or_chain = model_class.where(conditions)
      end
    end

    or_chain
  end

  def self.select_by_new_ids(model_class, target_id)
    RedisMemo::Tracer.trace(
      'redis_memo.memoize_query.invalidation',
      "#{__method__}##{model_class.name}",
    ) do
      RedisMemo.without_memoization do
        model_class.where(
          model_class.arel_table[model_class.primary_key].gt(target_id),
        ).to_a
      end
    end
  end

  def self.select_by_conflict_target_relation(model_class, relation)
    return [] unless relation

    RedisMemo::Tracer.trace(
      'redis_memo.memoize_query.invalidation',
      "#{__method__}##{model_class.name}",
    ) do
      RedisMemo.without_memoization { relation.reload }
    end
  end
end
