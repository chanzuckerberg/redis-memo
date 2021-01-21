# typed: false

class RedisMemo::MemoizeRecords::ModelCallback
  def self.install(model_class)
    var_name = :@@__redis_memo_memoize_record_after_save_callback_installed__
    return if model_class.class_variable_defined?(var_name)

    model_class.after_save(new)
    model_class.after_destroy(new)

    model_class.class_variable_set(var_name, true)
  end

  def after_save(record)
    RedisMemo::MemoizeRecords.invalidate(record)
  end

  def after_destroy(record)
    RedisMemo::MemoizeRecords.invalidate(record)
  end
end
