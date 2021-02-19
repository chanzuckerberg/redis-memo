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

      %i(delete decrement! increment!).each do |method_name|
        alias_method :"without_redis_memo_invalidation_#{method_name}", method_name

        define_method method_name do |*args|
          result = send(:"without_redis_memo_invalidation_#{method_name}", *args)

          RedisMemo::MemoizeQuery.invalidate(self)

          result
        end
      end
    end

    # Methods that won't trigger model callbacks
    # https://guides.rubyonrails.org/active_record_callbacks.html#skipping-callbacks
    %i(
      decrement_counter
      delete_all delete_by
      increment_counter
      insert insert! insert_all insert_all!
      touch_all
      update_column update_columns update_all update_counters
      upsert upsert_all
    ).each do |method_name|
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

    %i(
      import import!
    ).each do |method_name|
      rewrite_import_method(
        model_class,
        method_name,
      )
    end

    model_class.class_variable_set(var_name, true)
  end

  private

  #
  # There’s no good way to perform fine-grind cache invalidation when
  # operations are bulk update operations such as update_all, and delete_all
  # witout fetching additional data from the database, which might lead to
  # performance degradation. Thus, by default, we simply invalidate all
  # existing cached records after each bulk_updates.
  #
  def self.rewrite_default_method(model_class, klass, method_name, class_method:)
    methods = class_method ? :methods : :instance_methods
    return unless klass.send(methods).include?(method_name)

    klass = klass.singleton_class if class_method
    klass.class_eval do
      alias_method :"#{method_name}_without_redis_memo_invalidation", method_name

      define_method method_name do |*args|
        result = send(:"#{method_name}_without_redis_memo_invalidation", *args)
        RedisMemo::MemoizeQuery.invalidate_all(model_class)
        result
      end
    end
  end

  def self.rewrite_import_method(model_class, method_name)
    # This optimization to avoid over-invalidation only works on postgres
    unless ActiveRecord::Base.connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
      rewrite_default_method(model_class, model_class, method_name, class_method: true)
      return
    end

    model_class.singleton_class.class_eval do
      alias_method :"#{method_name}_without_redis_memo_invalidation", method_name

      # For the args format, see
      # https://github.com/zdennis/activerecord-import/blob/master/lib/activerecord-import/import.rb#L128
      define_method method_name do |*args, &blk|
        options = args.last.is_a?(Hash) ? args.last : {}
        records = args[args.last.is_a?(Hash) ? -2 : -1]
        columns_to_update = options[:on_duplicate_key_update]
        if columns_to_update.is_a?(Hash)
          columns_to_update = columns_to_update[:columns]
        end

        if records.last.is_a?(Hash)
          records.map! { |hash| model_class.new(hash) }
        end

        # Invalidate the records before and after the import to resolve
        # - default values filled by the database
        # - updates on conflict conditions
        records_to_invalidate =
          if columns_to_update
            RedisMemo::MemoizeQuery::Invalidation.send(
              :select_by_columns,
              model_class,
              records,
              columns_to_update,
            )
          else
            []
          end

        result = send(:"#{method_name}_without_redis_memo_invalidation", *args, &blk)

        # Offload the records to invalidate while selecting the next set of
        # records to invalidate
        case records_to_invalidate
        when Array
          RedisMemo::MemoizeQuery.invalidate(*records_to_invalidate) unless records_to_invalidate.empty?

          RedisMemo::MemoizeQuery.invalidate(*RedisMemo::MemoizeQuery::Invalidation.send(
            :select_by_id,
            model_class,
            # Not all databases support "RETURNING", which is useful when
            # invaldating records after bulk creation
            result.ids,
          ))
        else
          RedisMemo::MemoizeQuery.invalidate_all(model_class)
        end

        result
      end
    end
  end

  def self.select_by_columns(model_class, records, columns_to_update)
    return [] if records.empty?

    or_chain = nil
    columns_to_select = columns_to_update & RedisMemo::MemoizeQuery
      .memoized_columns(model_class)
      .to_a.flatten.uniq

    # Nothing to invalidate here
    return [] if columns_to_select.empty?

    RedisMemo::Tracer.trace(
      'redis_memo.memoize_query.invalidation',
      "#{__method__}##{model_class.name}",
    ) do
      records.each do |record|
        conditions = {}
        columns_to_select.each do |column|
          conditions[column] = record.send(column)
        end
        if or_chain
          or_chain = or_chain.or(model_class.where(conditions))
        else
          or_chain = model_class.where(conditions)
        end
      end

      record_count = RedisMemo.without_memo { or_chain.count }
      if record_count > bulk_operations_invalidation_limit
        nil
      else
        RedisMemo.without_memo { or_chain.to_a }
      end
    end
  end

  def self.select_by_id(model_class, ids)
    RedisMemo::Tracer.trace(
      'redis_memo.memoize_query.invalidation',
      "#{__method__}##{model_class.name}",
    ) do
      RedisMemo.without_memo do
        model_class.where(model_class.primary_key => ids).to_a
      end
    end
  end

  def self.bulk_operations_invalidation_limit
    ENV['REDIS_MEMO_BULK_OPERATIONS_INVALIDATION_LIMIT']&.to_i ||
      RedisMemo::DefaultOptions.bulk_operations_invalidation_limit ||
      10000
  end
end
