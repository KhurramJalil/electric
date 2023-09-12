defmodule Electric.Postgres.Extension.Migrations.Migration_20230605141256_ElectrifyFunction do
  alias Electric.Postgres.Extension

  require EEx

  @behaviour Extension.Migration

  sql_template = Path.expand("20230605141256_electrify_function/electrify.sql.eex", __DIR__)

  @external_resource sql_template

  @impl true
  def version, do: 2023_06_05_14_12_56

  @impl true
  def up(schema) do
    electrified_tracking_table = Extension.electrified_tracking_table()
    electrified_index_table = Extension.electrified_index_table()
    publication = Extension.publication_name()

    electrify_function =
      electrify_function_sql(
        schema,
        electrified_tracking_table,
        Extension.electrified_index_table(),
        publication,
        Extension.add_table_to_publication_sql("%I.%I")
      )

    [
      """
      CREATE TABLE #{electrified_tracking_table} (
          id          int8 NOT NULL PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY,
          schema_name text NOT NULL,
          table_name  text NOT NULL,
          oid         oid NOT NULL,
          created_at  timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
          CONSTRAINT unique_table_name UNIQUE (schema_name, table_name)
      );
      """,
      """
      CREATE INDEX #{Extension.electrified_tracking_relation()}_name_idx ON #{electrified_tracking_table} (schema_name, table_name);
      CREATE INDEX #{Extension.electrified_tracking_relation()}_oid_idx ON #{electrified_tracking_table} (oid);
      """,
      """
      CREATE TABLE #{electrified_index_table} (
          id          oid NOT NULL PRIMARY KEY,
          table_id    int8 NOT NULL REFERENCES #{electrified_tracking_table} (id) ON DELETE CASCADE,
          created_at  timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      """,
      Extension.add_table_to_publication_sql(electrified_tracking_table),
      electrify_function
      # """
      # CREATE EVENT TRIGGER #{event_triggers[:sql_drop]} ON sql_drop
      #     WHEN TAG IN (#{Enum.join(event_trigger_tags, ", ")})
      #     EXECUTE FUNCTION #{schema}.ddlx_sql_drop_handler();
      # """
    ]
  end

  @impl true
  def down(_schema) do
    []
  end

  EEx.function_from_file(:defp, :electrify_function_sql, sql_template, [
    :schema,
    :electrified_tracking_table,
    :electrified_index_table,
    :publication_name,
    :publication_sql
  ])
end
