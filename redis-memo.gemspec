# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name          = 'redis-memo'
  s.version       = '0.0.0.beta.2'
  s.date          = '2020-10-31'
  s.summary       = 'A Redis-based version-addressable caching system. Memoize pure functions, aggregated database queries, and 3rd party API calls.'
  s.authors       = ['Chan Zuckerberg Initiative']
  s.email         = 'opensource@chanzuckerberg.com'
  s.homepage      = 'https://github.com/chanzuckerberg/redis-memo'
  s.license       = 'MIT'
  s.require_paths = ['lib']
  s.files         = Dir.glob('lib/**/*')

  s.required_ruby_version = ['>= 2.5.0']

  s.add_dependency 'activesupport', '~> 5.2'
  s.add_dependency 'redis', '~> 4'

  s.add_development_dependency 'activerecord', '~> 5.2'
  s.add_development_dependency 'activerecord-import'
  s.add_development_dependency 'codecov'
  s.add_development_dependency 'database_cleaner-active_record'
  s.add_development_dependency 'pg'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'rspec', '~> 3.2'
  s.add_development_dependency 'simplecov'
end
