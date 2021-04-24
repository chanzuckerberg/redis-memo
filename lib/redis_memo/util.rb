# frozen_string_literal: true
module RedisMemo::Util
  def self.checksum(serialized)
    Digest::SHA1.base64digest(serialized)
  end

  def self.deep_sort_hash(orig_hash)
    {}.tap do |new_hash|
      orig_hash.sort.each do |k, v|
        new_hash[k] = v.is_a?(Hash) ? deep_sort_hash(v) : v
      end
    end
  end

  def self.uuid
    SecureRandom.uuid
  end
end
