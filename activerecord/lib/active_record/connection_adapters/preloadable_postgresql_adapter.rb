# frozen_string_literal: true
require "active_record/connection_adapters/postgresql_adapter"

module ActiveRecord::ConnectionAdapters
  class PreloadablePostgreSQLAdapter < ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
    ADAPTER_NAME = "PreloadablePostgreSQL".freeze

    def initialize(...)
      super
      @__preload = {}
      preload(tables)
    end

    CACHEABLE_METHODS = [
      :column_definitions,
      :primary_keys,
      :table_options,
      :indexes,
    ].freeze

    def preload(table_names)
      preload_column_definitions(table_names)
      CACHEABLE_METHODS.each do |method_name|
        preload_method = "preload_#{method_name}"
        send(preload_method, table_names)
      end
    end

    CACHEABLE_METHODS.each do |method_name |
      define_method(method_name) do |table_name|
        get_cached_or_compute(method_name, table_name) { super(table_name) }
      end
    end

    private

    def preload_column_definitions(table_names)
      @__preload[:column_definitions] = table_names.map do |table_name|
        [
          table_name,
          query(<<~SQL, "SCHEMA")
            SELECT a.attname, format_type(a.atttypid, a.atttypmod),
                   pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod,
                   c.collname, col_description(a.attrelid, a.attnum) AS comment,
                   #{supports_identity_columns? ? 'attidentity' : quote('')} AS identity,
                   #{supports_virtual_columns? ? 'attgenerated' : quote('')} as attgenerated
              FROM pg_attribute a
              LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
              LEFT JOIN pg_type t ON a.atttypid = t.oid
              LEFT JOIN pg_collation c ON a.attcollation = c.oid AND a.attcollation <> t.typcollation
             WHERE a.attrelid = #{quote(quote_table_name(table_name))}::regclass
               AND a.attnum > 0 AND NOT a.attisdropped
             ORDER BY a.attnum
          SQL
        ]
      end.to_h
    end

    def preload_primary_keys(table_names)
      @__preload[:primary_keys] = table_names.map do |table_name|
        [
          table_name,
          query_values(<<~SQL, "SCHEMA")
            SELECT a.attname
              FROM (
                     SELECT indrelid, indkey, generate_subscripts(indkey, 1) idx
                       FROM pg_index
                      WHERE indrelid = #{quote(quote_table_name(table_name))}::regclass
                        AND indisprimary
                   ) i
              JOIN pg_attribute a
                ON a.attrelid = i.indrelid
               AND a.attnum = i.indkey[i.idx]
             ORDER BY i.idx
          SQL
        ]
      end.to_h
    end

    def preload_table_options(table_names)
      @__preload[:table_options] ||= table_names.map do |table_name|
        options = {}

        comment = table_comment(table_name)

        options[:comment] = comment if comment

        inherited_table_names = inherited_table_names(table_name).presence

        options[:options] = "INHERITS (#{inherited_table_names.join(", ")})" if inherited_table_names

        if !options[:options] && supports_native_partitioning?
          partition_definition = table_partition_definition(table_name)

          options[:options] = "PARTITION BY #{partition_definition}" if partition_definition
        end

        [
          table_name,
          options
        ]
      end.to_h
    end

    def preload_indexes(table_names)
      @__preload[:table_options] ||= table_names.map do |table_name|
        scope = quoted_scope(table_name)

        result = query(<<~SQL, "SCHEMA")
              SELECT distinct i.relname, d.indisunique, d.indkey, pg_get_indexdef(d.indexrelid),
                              pg_catalog.obj_description(i.oid, 'pg_class') AS comment, d.indisvalid,
                              ARRAY(
                                SELECT pg_get_indexdef(d.indexrelid, k + 1, true)
                                FROM generate_subscripts(d.indkey, 1) AS k
                                ORDER BY k
                              ) AS columns
              FROM pg_class t
              INNER JOIN pg_index d ON t.oid = d.indrelid
              INNER JOIN pg_class i ON d.indexrelid = i.oid
              LEFT JOIN pg_namespace n ON n.oid = t.relnamespace
              WHERE i.relkind IN ('i', 'I')
                AND d.indisprimary = 'f'
                AND t.relname = #{scope[:name]}
                AND n.nspname = #{scope[:schema]}
              ORDER BY i.relname
            SQL

        result.map do |row|
          index_name = row[0]
          unique = row[1]
          indkey = row[2].split(" ").map(&:to_i)
          inddef = row[3]
          comment = row[4]
          valid = row[5]
          columns = decode_string_array(row[6]).map { |c| Utils.unquote_identifier(c.strip.gsub('""', '"')) }

          using, expressions, include, nulls_not_distinct, where = inddef.scan(/ USING (\w+?) \((.+?)\)(?: INCLUDE \((.+?)\))?( NULLS NOT DISTINCT)?(?: WHERE (.+))?\z/m).flatten

          orders = {}
          opclasses = {}
          include_columns = include ? include.split(",").map { |c| Utils.unquote_identifier(c.strip.gsub('""', '"')) } : []

          if indkey.include?(0)
            columns = expressions
          else
            # prevent INCLUDE columns from being matched
            columns.reject! { |c| include_columns.include?(c) }

            # add info on sort order (only desc order is explicitly specified, asc is the default)
            # and non-default opclasses
            expressions.scan(/(?<column>\w+)"?\s?(?<opclass>\w+_ops(_\w+)?)?\s?(?<desc>DESC)?\s?(?<nulls>NULLS (?:FIRST|LAST))?/).each do |column, opclass, desc, nulls|
              opclasses[column] = opclass.to_sym if opclass
              if nulls
                orders[column] = [desc, nulls].compact.join(" ")
              else
                orders[column] = :desc if desc
              end
            end
          end

          [
            table_name,
            IndexDefinition.new(
              table_name,
              index_name,
              unique,
              columns,
              orders: orders,
              opclasses: opclasses,
              where: where,
              using: using.to_sym,
              include: include_columns.presence,
              nulls_not_distinct: nulls_not_distinct.present?,
              comment: comment.presence,
              valid: valid
            )
          ]
        end
      end.to_h
    end

    def get_cached_or_compute(cache_key, table_name)
      @__preload&.dig(cache_key, table_name) || yield
    end
  end
end