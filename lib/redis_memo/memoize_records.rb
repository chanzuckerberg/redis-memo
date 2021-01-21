# typed: false

#
# Automatically invalidate memoizable when modifying ActiveRecords objects.
# You still need to invalidate memos when you are using SQL queries to perform
# update / delete (does not trigger record callbacks)
#
module RedisMemo::MemoizeRecords
  # TODO: MemoizeRecords -> MemoizeQuery
  def memoize_records
    RedisMemo::MemoizeRecords.using_active_record!(self)

    memoize_table_column(primary_key.to_sym, editable: false)
  end

  # Only editable columns will be used to create memos that are invalidatable
  # after each record save
  def memoize_table_column(*raw_columns, editable: true)
    RedisMemo::MemoizeRecords.using_active_record!(self)

    columns = raw_columns.map(&:to_sym).sort

    RedisMemo::MemoizeRecords.memoized_columns(self, editable_only: true) << columns if editable
    RedisMemo::MemoizeRecords.memoized_columns(self, editable_only: false) << columns

    RedisMemo::MemoizeRecords::ModelCallback.install(self)
    RedisMemo::MemoizeRecords::Invalidation.install(self)

    if ENV['REDIS_MEMO_DISABLE_CACHED_SELECT'] != 'true'
      RedisMemo::MemoizeRecords::CachedSelect.install(ActiveRecord::Base.connection)
    end

    columns.each do |column|
      unless self.columns_hash.include?(column.to_s)
        raise(
          RedisMemo::ArgumentError,
          "'#{self.name}' does not contain column '#{column}'",
        )
      end
    end
  rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
    # no-opts: models with memoize_table_column decleared might be loaded in
    # rake tasks that are used to create databases
  end

  def self.using_active_record!(model_class)
    unless model_class.respond_to?(:<) && model_class < ActiveRecord::Base
      raise RedisMemo::ArgumentError, "'#{model_class.name}' does not use ActiveRecord"
    end
  end

  @@memoized_columns = Hash.new { |h, k| h[k] = [Set.new, Set.new] }

  def self.memoized_columns(model_or_table, editable_only: false)
    table = model_or_table.is_a?(Class) ? model_or_table.table_name : model_or_table
    @@memoized_columns[table.to_sym][editable_only ? 1 : 0]
  end

  # extra_props are considered as AND conditions on the model class
  def self.create_memo(model_class, **extra_props)
    RedisMemo::MemoizeRecords.using_active_record!(model_class)

    keys = extra_props.keys.sort
    if !keys.empty? && !RedisMemo::MemoizeRecords.memoized_columns(model_class).include?(keys)
      raise(
        RedisMemo::ArgumentError,
        "'#{model_class.name}' has not memoized columns: #{keys}",
      )
    end

    extra_props.each do |key, values|
      # The data type is ensured by the database, thus we don't need to cast
      # types here for better performance
      column_name = key.to_s
      values = [values] unless values.is_a?(Enumerable)
      extra_props[key] =
        if model_class.defined_enums.include?(column_name)
          enum_mapping = model_class.defined_enums[column_name]
          values.map do |value|
            # Assume a value is a converted enum if it does not exist in the
            # enum mapping
            (enum_mapping[value.to_s] || value).to_s
          end
        else
          values.map(&:to_s)
        end
    end

    RedisMemo::Memoizable.new(
      __redis_memo_memoize_records_model_class_name__: model_class.name,
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

  def self.invalidate(record)
    # Invalidate memos with current values
    memos_to_invalidate = memoized_columns(record.class).map do |columns|
      props = {}
      columns.each do |column|
        props[column] = record.send(column)
      end

      RedisMemo::MemoizeRecords.create_memo(record.class, **props)
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

          props[column] = record.send(column)
        end

        memos_to_invalidate << RedisMemo::MemoizeRecords.create_memo(record.class, **props)
      end
    end

    RedisMemo::Memoizable.invalidate(memos_to_invalidate)
  end
end
