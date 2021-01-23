#!/usr/bin/env rake
require 'bundler/gem_tasks'

task :default => ['test:all']

namespace :test do
  desc "test all drivers"
  task :all => [:mysql2, :postgresql, :sqlite]

  desc "test mysql driver"
  task :mysql do
    sh "RSPEC_DB_ADAPTER=mysql bundle exec rspec"
  end

  desc "test mysql2 driver"
  task :mysql2 do
    sh "RSPEC_DB_ADAPTER=mysql2 bundle exec rspec"
  end

  desc "test PostgreSQL driver"
  task :postgresql do
    sh "RSPEC_DB_ADAPTER=postgresql RSPEC_DB_USERNAME=postgres bundle exec rspec"
  end

  desc "test sqlite3 driver"
  task :sqlite do
    sh "RSPEC_DB_ADAPTER=sqlite3 bundle exec rspec"
  end
end

namespace :db do

  desc "reset all databases"
  task :reset => [:"mysql:reset", :"postgresql:reset"]

  namespace :mysql do
    desc "reset MySQL database"
    task :reset => [:drop, :create]

    desc "create MySQL database"
    task :create do
      sh 'mysql -u root -e "create database redis_memo_test;"'
    end

    desc "drop MySQL database"
    task :drop do
      sh 'mysql -u root -e "drop database if exists redis_memo_test;"'
    end
  end

  namespace :postgresql do
    desc "reset PostgreSQL database"
    task :reset => [:drop, :create]

    desc "create PostgreSQL database"
    task :create do
      sh 'createdb -U postgres redis_memo_test'
    end

    desc "drop PostgreSQL database"
    task :drop do
      sh 'psql -d postgres -U postgres -c "DROP DATABASE IF EXISTS redis_memo_test"'
    end
  end
end
