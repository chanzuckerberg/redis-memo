# frozen_string_literal: true

# TODO: -> RedisMemo::Memoizable::AfterCommit

class RedisMemo::AfterCommit
  # We assume there's only one ActiveRecord DB connection used for opening
  # transactions
  @@callback_added = false
  @@pending_memo_versions = {}
  @@previous_memo_versions = {}

  def self.connection
    ActiveRecord::Base.connection
  end

  def self.pending_memo_versions
    # In DB transactions, the pending memo version should be used immediately
    # as part of method checksums. method_cache_keys made of
    # pending_memo_versions are not referencable until we bump the
    # pending_memo_versions after commiting the current transaction
    @@pending_memo_versions
  end

  def self.bump_memo_version_after_commit(key, version, previous_version:)
    @@pending_memo_versions[key] = version
    @@previous_memo_versions[key] = previous_version

    reset_after_transaction
  end

  # https://github.com/Envek/after_commit_everywhere/blob/be8602f9fbb8e40b0fc8a04a47e4c2bc6b560ad5/lib/after_commit_everywhere.rb#L93
  # Helper method to determine whether we're currently in transaction or not
  def self.in_transaction?
    # service transactions (tests and database_cleaner) are not joinable
    connection.transaction_open? && connection.current_transaction.joinable?
  end

  def self.after_commit(&blk)
    connection.add_transaction_record(
      RedisMemo::AfterCommit::Callback.new(connection, committed: blk),
    )
  end

  def self.after_rollback(&blk)
    connection.add_transaction_record(
      RedisMemo::AfterCommit::Callback.new(connection, rolledback: blk),
    )
  end

  def self.reset_after_transaction
    return if @@callback_added

    @@callback_added = true

    after_commit do
      reset(commited: true)
    end

    after_rollback do
      reset(commited: false)
    end
  end

  def self.reset(commited:)
    if commited
      @@pending_memo_versions.each do |key, version|
        invalidation_queue =
          RedisMemo::Memoizable::Invalidation.class_variable_get(:@@invalidation_queue)

        invalidation_queue << RedisMemo::Memoizable::Invalidation::Task.new(
          key,
          version,
          @@previous_memo_versions[key],
        )
      end

      RedisMemo::Memoizable::Invalidation.drain_invalidation_queue
    else
      @@pending_memo_versions.each_key do |key|
        RedisMemo::Cache.local_cache&.delete(key)
      end
    end
    @@callback_added = false
    @@pending_memo_versions.clear
    @@previous_memo_versions.clear
  end

  # https://github.com/Envek/after_commit_everywhere/blob/master/lib/after_commit_everywhere/wrap.rb
  class Callback
    def initialize(connection, committed: nil, rolledback: nil)
      @connection = connection
      @committed = committed
      @rolledback = rolledback
    end

    def has_transactional_callbacks?
      true
    end

    def trigger_transactional_callbacks?
      true
    end

    def committed!(*)
      @committed&.call
    end

    # Required for +transaction(requires_new: true)+
    def add_to_transaction(*)
      @connection.add_transaction_record(self)
    end

    def before_committed!(*); end

    def rolledback!(*)
      @rolledback&.call
    end
  end
end
