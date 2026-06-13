# =============================================================================
# modules/snowflake_project/outputs.tf
# -----------------------------------------------------------------------------
# Outputs consumed by the root module / downstream tooling (e.g. dbt profiles,
# CI configuration). No secrets are exported.
# =============================================================================

output "database_name" {
  description = "Name of the managed claims database."
  value       = snowflake_database.claims.name
}

output "schema_names" {
  description = "Map of schema key -> created schema name."
  value       = { for k, s in snowflake_schema.schemas : k => s.name }
}

output "warehouse_names" {
  description = "Map of warehouse key -> created warehouse name."
  value       = { for k, w in snowflake_warehouse.warehouses : k => w.name }
}

output "role_names" {
  description = "Map of role key -> created account role name."
  value       = { for k, r in snowflake_account_role.roles : k => r.name }
}

output "stage_fully_qualified_names" {
  description = "Map of source feed -> fully-qualified internal stage name (DB.SCHEMA.STAGE)."
  value = {
    for k, st in snowflake_stage.raw_feeds :
    k => "${st.database}.${st.schema}.${st.name}"
  }
}

output "file_format_names" {
  description = "Map of file format key -> fully-qualified file format name."
  value = {
    ndjson = "${snowflake_file_format.ndjson.database}.${snowflake_file_format.ndjson.schema}.${snowflake_file_format.ndjson.name}"
    csv    = "${snowflake_file_format.csv_seed.database}.${snowflake_file_format.csv_seed.schema}.${snowflake_file_format.csv_seed.name}"
  }
}
