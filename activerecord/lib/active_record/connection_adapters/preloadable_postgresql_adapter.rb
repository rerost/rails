# frozen_string_literal: true
require "active_record/connection_adapters/postgresql_adapter"

module ActiveRecord::ConnectionAdapters
  class PreloadablePostgreSQLAdapter < ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
    ADAPTER_NAME = "PreloadablePostgreSQL".freeze
  end
end