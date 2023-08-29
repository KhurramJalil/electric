defmodule Electric.Postgres.Extension.Migrations.Migration_20230328113927 do
  alias Electric.Postgres.Extension

  @behaviour Extension.Migration
  # https://www.postgresql.org/docs/current/functions-info.html#FUNCTIONS-PG-SNAPSHOT
  # pg_current_xact_id() -> xid8
  # The internal transaction ID type .. xid8 ... [id] a 64-bit type xid8 that
  # does not wrap around during the life of an installation
  @txid_type "xid8"
  @current_tx_id "pg_current_xact_id()"
  @current_tx_ts "transaction_timestamp()"

  @impl true
  def version, do: 2023_03_28_11_39_27

  def is_current_txid(prefix \\ ""),
    do: "#{prefix}txid = #{@current_tx_id} AND #{prefix}txts = #{@current_tx_ts}"

  @impl true
  def up(schema) do
    ddl_table = Extension.ddl_table()
    schema_table = Extension.schema_table()
    version_table = Extension.version_table()
    event_triggers = Extension.event_triggers()
    publication_name = Extension.publication_name()

    event_trigger_tags =
      for action <- ["CREATE", "ALTER", "DROP"],
          obj <- ["TABLE", "INDEX", "VIEW"],
          do: "'#{action} #{obj}'"

    [
      """
      CREATE TABLE #{version_table} (
          txid #{@txid_type} NOT NULL,
          txts timestamp with time zone NOT NULL,
          version varchar(255) NOT NULL,
          PRIMARY KEY (txid, txts),
          CONSTRAINT "migration_unique_version" UNIQUE (version),
          CONSTRAINT "migration_unique_fk" UNIQUE (txid, txts, version)
      );
      """,
      ##################
      """
      CREATE TABLE #{ddl_table} (
          id int8 NOT NULL PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY,
          txid #{@txid_type} NOT NULL,
          txts timestamp with time zone NOT NULL,
          query text NOT NULL
          -- we create the version after any ddl has been captured
          -- FOREIGN KEY (txid, txts) REFERENCES #{version_table} (txid, txts)
      );
      """,
      ##################
      """
      CREATE TABLE #{schema_table} (
          id int8 NOT NULL PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY,
          version varchar(255) NOT NULL,
          schema jsonb NOT NULL,
          migration_ddl text[] NOT NULL,
          created_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      """,
      ##################
      """
      CREATE UNIQUE INDEX electric_schema_version_idx ON #{schema_table} (version);
      """,
      ##################
      """
      CREATE OR REPLACE FUNCTION #{schema}.migration_version(
          _v text,
          OUT txid #{@txid_type},
          OUT txts timestamptz,
          OUT version text
      ) AS $function$
      DECLARE
          _version record;
      BEGIN
          SELECT t.txid, t.txts INTO txid, txts FROM #{schema}.current_transaction_id() t;
          INSERT INTO #{version_table} AS v
              (txid, txts, version)
            VALUES
              (txid, txts, _v)
            RETURNING v.txid, v.txts, v.version INTO txid, txts, version;
      END;
      $function$ LANGUAGE PLPGSQL;
      """,
      ##################
      """
      CREATE OR REPLACE FUNCTION #{schema}.assign_migration_version(
          _v text,
          OUT txid #{@txid_type},
          OUT txts timestamptz,
          OUT version text
      ) AS $function$
      -- DECLARE
      --   _version record;
      BEGIN
          INSERT INTO #{version_table} AS v
              (txid, txts, version)
            VALUES
              (#{@current_tx_id}, #{@current_tx_ts}, _v)
            RETURNING v.txid, v.txts, v.version INTO txid, txts, version;
      END;
      $function$ LANGUAGE PLPGSQL;
      """,
      ##################
      """
      CREATE OR REPLACE FUNCTION #{schema}.current_transaction_id(
          OUT txid #{@txid_type},
          OUT txts timestamptz
      ) AS $function$
      DECLARE
          _v text;
          _version record;
      BEGIN
          -- SELECT v.txid, v.txts
          --     INTO txid, txts
          --     FROM #{version_table} v
          --     WHERE #{is_current_txid("v.")} LIMIT 1;

          -- IF NOT FOUND THEN
          --   _v := (SELECT to_char(#{@current_tx_ts}, 'YYYYMMDDHH24MISS_FF3'));
          --   -- TODO: we should instead abort the transaction
          --   --       not doing that now because it would break everything
          --   RAISE WARNING 'assigning automatic migration version id: %', _v;
          --   SELECT v.txid, v.txts INTO txid, txts FROM #{schema}.migration_version(_v) v;
          -- ELSE
          --   RAISE DEBUG 'got active version %', version;
          -- END IF;
          -- SELECT v.txid, v.txts INTO txid, txts FROM #{schema}.migration_version(_v) v;
          -- SELECT (#{@current_tx_id}, #{@current_tx_ts}) INTO txid, txts;
          txid := (SELECT #{@current_tx_id});
          txts := (SELECT #{@current_tx_ts});
      END;
      $function$ LANGUAGE PLPGSQL;
      """,
      ##################
      """
      CREATE OR REPLACE FUNCTION #{schema}.create_active_migration(
        _txid #{@txid_type}, 
        _txts timestamptz, 
        _query text DEFAULT NULL
      ) RETURNS int8 AS
      $function$
      DECLARE
          trid int8;
      BEGIN
          IF _query IS NULL THEN
              _query := current_query();
          END IF;
          RAISE DEBUG 'capture migration: %', _query;
          INSERT INTO #{ddl_table} (txid, txts, query) 
            VALUES (_txid, _txts, _query)
            RETURNING id INTO trid;
          RETURN trid;
      END;
      $function$
      LANGUAGE PLPGSQL;
      """,
      ##################
      """
      CREATE OR REPLACE FUNCTION #{schema}.active_migration_id() RETURNS int8 AS
      $function$
      DECLARE
          trid int8;
      BEGIN
      SELECT id INTO trid FROM #{ddl_table} WHERE #{is_current_txid()} ORDER BY id DESC LIMIT 1;
          RETURN trid;
      END;
      $function$
      LANGUAGE PLPGSQL;
      """,
      ##################
      # this function is over-written by later versions
      """
      CREATE OR REPLACE FUNCTION #{schema}.ddlx_command_end_handler() 
          RETURNS EVENT_TRIGGER AS $function$
      BEGIN
          NULL;
      END;
      $function$ LANGUAGE PLPGSQL;
      """,
      ##################
      """
      CREATE EVENT TRIGGER #{event_triggers[:ddl_command_end]} ON ddl_command_end
          WHEN TAG IN (#{Enum.join(event_trigger_tags, ", ")})
          EXECUTE FUNCTION #{schema}.ddlx_command_end_handler();
      """,
      """
      CREATE PUBLICATION "#{publication_name}"; 
      """,
      Extension.add_table_to_publication_sql(ddl_table)
    ]
  end

  @impl true
  def down(_schema) do
    []
  end
end
