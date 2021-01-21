# frozen_string_literal: true
require 'securerandom'

class RedisMemo::Memoizable
  require_relative 'memoizable/dependency'
  require_relative 'memoizable/invalidation'

  attr_accessor :props
  attr_reader :depends_on

  def initialize(**props, &depends_on)
    @props = props
    @depends_on = depends_on
    @cache_key = nil
  end

  def extra_props(**args)
    instance = dup
    instance.props = props.dup.merge(**args)
    instance
  end

  def cache_key
    @cache_key ||= [
      self.class.name,
      RedisMemo.checksum(
        RedisMemo.deep_sort_hash(@props).to_json,
      ),
    ].join(':')
  end

  # Calculate the checksums for all memoizable groups in one Redis round trip
  def self.checksums(instances_groups)
    dependents_cache_keys = []
    cache_key_groups = instances_groups.map do |instances|
      cache_keys = instances.map(&:cache_key)
      dependents_cache_keys += cache_keys
      cache_keys
    end

    dependents_cache_keys.uniq!
    dependents_versions = find_or_create_versions(dependents_cache_keys)
    version_hash = dependents_cache_keys.zip(dependents_versions).to_h

    cache_key_groups.map do |cache_keys|
      RedisMemo.checksum(version_hash.slice(*cache_keys).to_json)
    end
  end

  def self.invalidate(instances)
    instances.each do |instance|
      cache_key = instance.cache_key
      RedisMemo::Memoizable::Invalidation.bump_version_later(
        cache_key,
        SecureRandom.uuid,
      )
    end

    RedisMemo::Memoizable::Invalidation.drain_invalidation_queue
  end

  private

  def self.find_or_create_versions(keys)
    need_to_bump_versions = false

    # Must check the local pending_memo_versions first in order to generate
    # memo checksums. The pending_memo_versions are the expected versions that
    # would be used if a transaction commited. With checksums consistent of
    # pending versions, the method results would only be visible after a
    # transaction commited (we bump the pending_memo_versions on redis as an
    # after_commit callback)
    if RedisMemo::AfterCommit.in_transaction?
      memo_versions = RedisMemo::AfterCommit.pending_memo_versions.slice(*keys)
    else
      memo_versions = {}
    end

    keys_to_fetch = keys
    keys_to_fetch -= memo_versions.keys unless memo_versions.empty?

    cached_versions =
      if keys_to_fetch.empty?
        {}
      else
        RedisMemo::Cache.read_multi(*keys_to_fetch, raise_error: true)
      end
    memo_versions.merge!(cached_versions) unless cached_versions.empty?

    versions = keys.map do |key|
      version = memo_versions[key]
      if version.nil?
        # If a version does not exist, we assume it's because the version has
        # expired due to TTL or it's evicted by a cache eviction policy. In
        # this case, we will create a new version and use it for memoizing the
        # cached result.
        need_to_bump_versions = true

        new_version = SecureRandom.uuid
        RedisMemo::Memoizable::Invalidation.bump_version_later(
          key,
          new_version,
          previous_version: '',
        )
        new_version
      else
        version
      end
    end

    # Flush out the versions to Redis (async) if we created new versions
    RedisMemo::Memoizable::Invalidation.drain_invalidation_queue if need_to_bump_versions

    versions
  end
end
