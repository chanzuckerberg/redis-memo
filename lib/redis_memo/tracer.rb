# frozen_string_literal: true
require_relative 'options'

class RedisMemo::Tracer
  def self.trace(span_name, method_id, &blk)
    tracer = RedisMemo::DefaultOptions.tracer
    return blk.call if tracer.nil?

    tracer.trace(span_name, resource: method_id, service: 'redis_memo') do
      blk.call
    end
  end

  def self.set_tag(**tags)
    tracer = RedisMemo::DefaultOptions.tracer
    return if tracer.nil? || !tracer.respond_to?(:active_span)

    active_span = tracer.active_span
    return if !active_span.respond_to?(:set_tag)

    tags.each do |name, value|
      active_span.set_tag(name, value)
    end
  end
end
