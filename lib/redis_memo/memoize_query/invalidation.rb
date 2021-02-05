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
        unique_by = options[:on_duplicate_key_update]
        if unique_by.is_a?(Hash)
          unique_by = unique_by[:columns]
        end

        if records.last.is_a?(Hash)
          records.map! { |hash| model_class.new(hash) }
        end

        # Invalidate the records before and after the import to resolve
        # - default values filled by the database
        # - updates on conflict conditions
        records_to_invalidate =
          if unique_by
            RedisMemo::MemoizeQuery::Invalidation.send(
              :select_by_uniq_index,
              records,
              unique_by,
            )
          else
            []
          end

        result = send(:"#{method_name}_without_redis_memo_invalidation", *args, &blk)

        records_to_invalidate += RedisMemo.without_memo do
          # Not all databases support "RETURNING", which is useful when
          # invaldating records after bulk creation
          model_class.where(model_class.primary_key => result.ids).to_a
        end

        memos_to_invalidate = records_to_invalidate.map do |record|
          RedisMemo::MemoizeQuery.to_memos(record)
        end
        RedisMemo::Memoizable.invalidate(memos_to_invalidate.flatten)

        result
      end
    end
  end

  def self.select_by_uniq_index(records, unique_by)
    model_class = records.first.class
    or_chain = nil

    records.each do |record|
      conditions = {}
      unique_by.each do |column|
        conditions[column] = record.send(column)
      end
      if or_chain
        or_chain = or_chain.or(model_class.where(conditions))
      else
        or_chain = model_class.where(conditions)
      end
    end

    RedisMemo.without_memo { or_chain.to_a }
  end
end
