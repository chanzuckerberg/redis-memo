# frozen_string_literal: true

class RedisMemo::MemoizeRecords::Invalidation
  def self.install(model_class)
    var_name = :@@__redis_memo_memoize_records_invalidation_installed__
    return if model_class.class_variable_defined?(var_name)

    model_class.class_eval do
      # A memory-persistent memoizable used for invalidating all queries of a
      # particular model
      def self.redis_memo_class_memoizable
        @redis_memo_class_memoizable ||= RedisMemo::MemoizeRecords.create_memo(self)
      end

      %i(delete decrement! increment!).each do |method_name|
        alias_method :"without_redis_memo_invalidation_#{method_name}", method_name

        define_method method_name do |*args|
          result = send(:"without_redis_memo_invalidation_#{method_name}", *args)

          RedisMemo::MemoizeRecords.invalidate(self)

          result
        end
      end
    end

    # Methods that won't trigger model callbacks
    # https://guides.rubyonrails.org/active_record_callbacks.html#skipping-callbacks
    %i(
      import
      decrement_counter
      delete_all delete_by
      increment_counter
      insert insert! insert_all insert_all!
      touch_all
      update_column update_columns update_all update_counters
      upsert upsert_all
    ).each do |method_name|
      # Example: Model.update_all
      rewrite_bulk_update_method(
        model_class,
        model_class,
        method_name,
        class_method: true,
      )

      # Example: Model.where(...).update_all
      rewrite_bulk_update_method(
        model_class,
        model_class.const_get(:ActiveRecord_Relation),
        method_name,
        class_method: false,
      )
    end

    model_class.class_variable_set(var_name, true)
  end

  private

  #
  # There’s no good way to perform fine-grind cache invalidation when operations
  # are bulk update operations such as import, update_all, and destroy_all:
  # Performing fine-grind cache invalidation would require the applications to
  # fetch additional data from the database, which might lead to performance
  # degradation. Thus we simply invalidate all existing cached records after each
  # bulk_updates.
  #
  def self.rewrite_bulk_update_method(model_class, klass, method_name, class_method:)
    methods = class_method ? :methods : :instance_methods
    return unless klass.send(methods).include?(method_name)

    klass = klass.singleton_class if class_method
    klass.class_eval do
      alias_method :"#{method_name}_without_redis_memo_invalidation", method_name

      define_method method_name do |*args|
        result = send(:"#{method_name}_without_redis_memo_invalidation", *args)
        RedisMemo::MemoizeRecords.invalidate_all(model_class)
        result
      end
    end
  end
end
