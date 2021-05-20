# frozen_string_literal: true

require_relative 'memoize_method'

# Hook into ActiveRecord to cache SQL queries and perform auto cache
# invalidation
module RedisMemo::MemoizeQuery
  require_relative 'memoize_query/cached_select'
  require_relative 'memoize_query/invalidation'
  require_relative 'memoize_query/model_callback'

  # Only editable columns will be used to create memos that are invalidatable
  # after each record save
  def memoize_table_column(*raw_columns, editable: true)
    RedisMemo::MemoizeQuery.using_active_record!(self)
    return if RedisMemo::DefaultOptions.disable_all
    return if RedisMemo::DefaultOptions.model_disabled_for_caching?(self)

    columns = raw_columns.map(&:to_sym).sort

    RedisMemo::MemoizeQuery.memoized_columns(self, editable_only: true) << columns if editable
    RedisMemo::MemoizeQuery.memoized_columns(self, editable_only: false) << columns

    RedisMemo::MemoizeQuery::ModelCallback.install(self)
    RedisMemo::MemoizeQuery::Invalidation.install(self)

    unless RedisMemo::DefaultOptions.disable_cached_select
      RedisMemo::MemoizeQuery::CachedSelect.install(ActiveRecord::Base.connection)
    end

    # The code below might fail due to missing DB/table errors
    columns.each do |column|
      next if columns_hash.include?(column.to_s)

      raise RedisMemo::ArgumentError.new("'#{name}' does not contain column '#{column}'")
    end

    unless RedisMemo::DefaultOptions.model_disabled_for_caching?(self)
      RedisMemo::MemoizeQuery::CachedSelect.enabled_models[table_name] = self
    end
  rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
    # no-opts: models with memoize_table_column decleared might be loaded in
    # rake tasks that are used to create databases
  end

  def self.using_active_record!(model_class)
    return if using_active_record?(model_class)

    raise RedisMemo::ArgumentError.new(
      "'#{model_class.name}' does not use ActiveRecord",
    )
  end

  def self.using_active_record?(model_class)
    model_class.respond_to?(:<) && model_class < ActiveRecord::Base
  end

  @@memoized_columns = Hash.new { |h, k| h[k] = [Set.new, Set.new] }

  def self.memoized_columns(model_or_table, editable_only: false)
    table = model_or_table.is_a?(Class) ? model_or_table.table_name : model_or_table
    @@memoized_columns[table.to_sym][editable_only ? 1 : 0]
  end

  # extra_props are considered as AND conditions on the model class
  def self.create_memo(model_class, **extra_props)
    using_active_record!(model_class)

    keys = extra_props.keys.sort
    if !keys.empty? && !memoized_columns(model_class).include?(keys)
      raise RedisMemo::ArgumentError.new("'#{model_class.name}' has not memoized columns: #{keys}")
    end

    extra_props.each do |key, value|
      # The data type is ensured by the database, thus we don't need to cast
      # types here for better performance
      column_name = key.to_s
      extra_props[key] =
        if model_class.defined_enums.include?(column_name)
          enum_mapping = model_class.defined_enums[column_name]
          # Assume a value is a converted enum if it does not exist in the
          # enum mapping
          (enum_mapping[value.to_s] || value).to_s
        else
          value.to_s
        end
    end

    RedisMemo::Memoizable.new(
      __redis_memo_memoize_query_table_name__: model_class.table_name,
      **extra_props,
    )
  end

  def self.invalidate_all(model_class)
    RedisMemo::Tracer.trace(
      'redis_memo.memoizable.invalidate_all',
      model_class.name,
    ) do
      RedisMemo::Memoizable.invalidate([model_class.redis_memo_class_memoizable])
    end
  end

  def self.invalidate(*records)
    RedisMemo::Memoizable.invalidate(
      records.map { |record| to_memos(record) }.flatten,
    )
  end

  def self.to_memos(record)
    # Invalidate memos with current values
    memos_to_invalidate = memoized_columns(record.class).map do |columns|
      props = {}
      columns.each do |column|
        props[column] = record.__send__(column)
      end

      create_memo(record.class, **props)
    end

    # Create memos with previous values if
    #  - there are saved changes
    #  - this is not creating a new record
    if !record.saved_changes.empty? && !record.saved_changes.include?(record.class.primary_key)
      previous_values = {}
      record.saved_changes.each do |column, (previous_value, _)|
        previous_values[column.to_sym] = previous_value
      end

      memoized_columns(record.class, editable_only: true).each do |columns|
        props = previous_values.slice(*columns)
        next if props.empty?

        # Fill the column values that have not changed
        columns.each do |column|
          next if props.include?(column)

          props[column] = record.__send__(column)
        end

        memos_to_invalidate << create_memo(record.class, **props)
      end
    end

    memos_to_invalidate
  end
end
