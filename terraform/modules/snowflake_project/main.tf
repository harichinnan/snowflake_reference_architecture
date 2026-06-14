# =============================================================================
# modules/snowflake_project/main.tf
# -----------------------------------------------------------------------------
# Platform footprint for the Snowflake Claims Platform: database, schemas,
# warehouses, roles, role hierarchy, least-privilege grants, internal stages,
# file formats, and optional service users.
#
# OWNERSHIP BOUNDARY:
#   - Terraform manages structural/security objects (this file).
#   - dbt manages transformation tables/views inside BRONZE..GOLD. We therefore
#     grant the TRANSFORMER role CREATE-object privileges on those schemas so
#     dbt can build models, but we do NOT create those models here.
# =============================================================================

terraform {
  required_providers {
    snowflake = {
      source                = "snowflakedb/snowflake"
      version               = ">= 0.90, < 2.0"
      # If using the SECURITYADMIN alias for role/grant management, declare the
      # configuration_aliases here:
      # configuration_aliases = [snowflake, snowflake.security_admin]
    }
  }
}

# -----------------------------------------------------------------------------
# Local definitions: the canonical set of schemas, warehouses, and roles.
# -----------------------------------------------------------------------------
locals {
  # 9 medallion + governance schemas.
  schemas = [
    "RAW",               # landing zone for raw feeds (loaded into internal stages)
    "BRONZE",            # raw-typed, lightly cleaned
    "SILVER_CANONICAL",  # conformed canonical entities
    "SILVER_DIMENSIONAL",# dimensional models (dims/facts)
    "GOLD",              # curated marts / serving layer
    "CONTROL",           # orchestration & run metadata (dbt artifacts, audit ctrl)
    "AUDIT",             # audit logs / data quality results
    "SEMANTIC",          # semantic views / metrics layer for BI & MCP
    "CORTEX",            # Cortex / AI search & analyst artifacts
  ]

  # Logical warehouse -> workload mapping. Sizes come from var.warehouse_sizes
  # (falling back to var.default_warehouse_size).
  warehouses = [
    "WH_CLAIMS_LOAD",      # ingestion / COPY INTO
    "WH_CLAIMS_TRANSFORM", # dbt runs (heaviest)
    "WH_CLAIMS_ANALYST",   # interactive analyst / BI queries
    "WH_CLAIMS_CI",        # CI test runs
    "WH_CLAIMS_MCP",       # MCP read-only serving
  ]

  # Functional (RBAC) roles.
  roles = [
    "CLAIMS_SYSADMIN",       # owns objects in the claims DB (under SYSADMIN)
    "CLAIMS_LOADER",         # ingestion
    "CLAIMS_TRANSFORMER",    # dbt transformations
    "CLAIMS_ANALYST",        # read curated data
    "CLAIMS_CI",             # CI pipeline (broad within env)
    "CLAIMS_MCP_READER",     # MCP read-only serving (narrow)
    "CLAIMS_SECURITY_ADMIN", # manages claims-scoped grants/roles (under SECURITYADMIN)
  ]

  # Source feeds -> internal stages in RAW.
  source_feeds = [
    "claims",
    "eligibility",
    "provider",
    "pharmacy",
    "adjudication",
  ]

  common_comment = "Managed by Terraform | project=snowflake-claims-platform | env=${var.environment}"
}

# =============================================================================
# DATABASE
# =============================================================================
resource "snowflake_database" "claims" {
  name    = var.database_name
  comment = local.common_comment

  # PRODUCTION HARDENING:
  #   - data_retention_time_in_days enables Time Travel; raise in prod for
  #     recoverability (Enterprise edition allows up to 90 days).
  #   - Consider a separate database for raw/landing vs serving if isolation is
  #     required; here a single DB with schema-level isolation is sufficient.
  data_retention_time_in_days = var.environment == "prod" ? 7 : 1
}

# =============================================================================
# SCHEMAS  (for_each over the canonical schema set)
# =============================================================================
resource "snowflake_schema" "schemas" {
  for_each = toset(local.schemas)

  database = snowflake_database.claims.name
  name     = each.value
  comment  = "${local.common_comment} | layer=${each.value}"

  # MANAGED ACCESS schemas: future grants on objects must be made by the schema
  # owner, centralizing access control. Strong production hardening default.
  with_managed_access = true

  # Inherit DB retention unless overridden.
  data_retention_time_in_days = var.environment == "prod" ? 7 : 1
}

# =============================================================================
# WAREHOUSES  (for_each over the warehouse set, sized from the map)
# =============================================================================
resource "snowflake_warehouse" "warehouses" {
  for_each = toset(local.warehouses)

  name           = each.value
  warehouse_size = lookup(var.warehouse_sizes, each.value, var.default_warehouse_size)
  comment        = "${local.common_comment} | warehouse=${each.value}"

  # Cost controls: suspend on idle, resume on demand, start suspended so an
  # apply does not incur immediate credits.
  auto_suspend        = var.auto_suspend_seconds
  auto_resume         = true
  initially_suspended = true

  # PRODUCTION HARDENING:
  #   - For TRANSFORM/ANALYST in prod consider multi-cluster (min/max cluster
  #     count) with STANDARD scaling policy to absorb concurrency:
  #       max_cluster_count = 3
  #       scaling_policy    = "STANDARD"
  #   - Attach a RESOURCE MONITOR (credit quota) to cap spend.
  #   - statement_timeout_in_seconds guards runaway queries.
  statement_timeout_in_seconds = var.environment == "prod" ? 3600 : 1800
}

# =============================================================================
# ROLES  (for_each over the role set)
# =============================================================================
resource "snowflake_account_role" "roles" {
  for_each = toset(local.roles)

  name    = each.value
  comment = "${local.common_comment} | role=${each.value}"
}

# =============================================================================
# ROLE HIERARCHY
# -----------------------------------------------------------------------------
# Functional roles roll up into CLAIMS_SYSADMIN, which rolls up into the
# built-in SYSADMIN so platform admins inherit visibility. The security role
# rolls up into SECURITYADMIN. This keeps the standard Snowflake hierarchy
# (SYSADMIN/SECURITYADMIN -> ACCOUNTADMIN) intact.
#
# NOTE on direction: snowflake_grant_account_role grants `role_name` TO
# `parent_role_name`, i.e. the parent INHERITS the child's privileges.
# =============================================================================

# CLAIMS_LOADER / TRANSFORMER / ANALYST / CI / MCP_READER -> CLAIMS_SYSADMIN
resource "snowflake_grant_account_role" "functional_to_claims_sysadmin" {
  for_each = toset([
    "CLAIMS_LOADER",
    "CLAIMS_TRANSFORMER",
    "CLAIMS_ANALYST",
    "CLAIMS_CI",
    "CLAIMS_MCP_READER",
  ])

  role_name        = snowflake_account_role.roles[each.value].name
  parent_role_name = snowflake_account_role.roles["CLAIMS_SYSADMIN"].name
}

# CLAIMS_SYSADMIN -> SYSADMIN (built-in)
resource "snowflake_grant_account_role" "claims_sysadmin_to_sysadmin" {
  role_name        = snowflake_account_role.roles["CLAIMS_SYSADMIN"].name
  parent_role_name = "SYSADMIN"
}

# CLAIMS_SECURITY_ADMIN -> SECURITYADMIN (built-in)
resource "snowflake_grant_account_role" "claims_security_to_securityadmin" {
  role_name        = snowflake_account_role.roles["CLAIMS_SECURITY_ADMIN"].name
  parent_role_name = "SECURITYADMIN"
}

# =============================================================================
# OWNERSHIP / BASELINE: let CLAIMS_SYSADMIN operate within the database.
# =============================================================================
resource "snowflake_grant_privileges_to_account_role" "sysadmin_db_usage" {
  account_role_name = snowflake_account_role.roles["CLAIMS_SYSADMIN"].name
  privileges        = ["USAGE", "CREATE SCHEMA"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.claims.name
  }
}

# =============================================================================
# LEAST-PRIVILEGE GRANTS
# -----------------------------------------------------------------------------
# Each functional role gets ONLY the schema/warehouse access its workload needs.
# We split grants into:
#   (a) DATABASE USAGE  (must see the DB to reach any schema)
#   (b) SCHEMA USAGE / CREATE (per role, per schema)
#   (c) Object privileges on existing + FUTURE tables/views (SELECT, and write
#       privileges only where the role produces data)
#   (d) WAREHOUSE USAGE (compute) on the role's dedicated warehouse
# Helper locals enumerate (role, schema) pairs to keep for_each readable.
# =============================================================================

locals {
  # Roles that need to see the database at all.
  db_usage_roles = [
    "CLAIMS_LOADER",
    "CLAIMS_TRANSFORMER",
    "CLAIMS_ANALYST",
    "CLAIMS_CI",
    "CLAIMS_MCP_READER",
  ]

  # ----- READ access (USAGE on schema + SELECT on tables/views) -----
  # role -> list of schemas it may READ.
  read_access = {
    CLAIMS_LOADER = ["RAW", "BRONZE"]
    CLAIMS_TRANSFORMER = [
      "BRONZE", "SILVER_CANONICAL", "SILVER_DIMENSIONAL",
      "GOLD", "CONTROL", "AUDIT",
    ]
    CLAIMS_ANALYST = ["GOLD", "SEMANTIC"]
    CLAIMS_CI = [
      "RAW", "BRONZE", "SILVER_CANONICAL", "SILVER_DIMENSIONAL",
      "GOLD", "CONTROL", "AUDIT", "SEMANTIC", "CORTEX",
    ]
    # MCP serving: read-only on serving layers + selected dimensional + audit
    # SUMMARIES. Deliberately NO RAW / NO BRONZE (no source PII-shaped data).
    CLAIMS_MCP_READER = ["GOLD", "SEMANTIC", "SILVER_DIMENSIONAL", "AUDIT"]
  }

  # ----- WRITE access (CREATE objects + INSERT/UPDATE/DELETE) -----
  # role -> list of schemas it may WRITE/produce data into.
  write_access = {
    # Loader lands raw + bronze data.
    CLAIMS_LOADER = ["RAW", "BRONZE"]
    # Transformer (dbt) builds models across the medallion + control/audit.
    CLAIMS_TRANSFORMER = [
      "BRONZE", "SILVER_CANONICAL", "SILVER_DIMENSIONAL",
      "GOLD", "CONTROL", "AUDIT",
    ]
    # CI may build/tear down everywhere within the (non-prod) env.
    CLAIMS_CI = [
      "RAW", "BRONZE", "SILVER_CANONICAL", "SILVER_DIMENSIONAL",
      "GOLD", "CONTROL", "AUDIT", "SEMANTIC", "CORTEX",
    ]
    # ANALYST and MCP_READER intentionally have NO write access.
  }

  # Flatten read_access into "ROLE|SCHEMA" pairs for for_each.
  read_pairs = merge([
    for role, schemas in local.read_access : {
      for s in schemas : "${role}|${s}" => { role = role, schema = s }
    }
  ]...)

  write_pairs = merge([
    for role, schemas in local.write_access : {
      for s in schemas : "${role}|${s}" => { role = role, schema = s }
    }
  ]...)

  # role -> dedicated warehouse.
  role_warehouse = {
    CLAIMS_LOADER      = "WH_CLAIMS_LOAD"
    CLAIMS_TRANSFORMER = "WH_CLAIMS_TRANSFORM"
    CLAIMS_ANALYST     = "WH_CLAIMS_ANALYST"
    CLAIMS_CI          = "WH_CLAIMS_CI"
    CLAIMS_MCP_READER  = "WH_CLAIMS_MCP"
  }
}

# --- (a) DATABASE USAGE for every functional role ---------------------------
resource "snowflake_grant_privileges_to_account_role" "db_usage" {
  for_each = toset(local.db_usage_roles)

  account_role_name = snowflake_account_role.roles[each.value].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.claims.name
  }
}

# --- (b) SCHEMA USAGE for READ roles ----------------------------------------
resource "snowflake_grant_privileges_to_account_role" "schema_usage_read" {
  for_each = local.read_pairs

  account_role_name = snowflake_account_role.roles[each.value.role].name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = "\"${snowflake_database.claims.name}\".\"${each.value.schema}\""
  }
  depends_on = [snowflake_schema.schemas]
}

# --- (b') SCHEMA CREATE privileges for WRITE roles --------------------------
# CREATE TABLE/VIEW/etc. so dbt (TRANSFORMER) and ingestion (LOADER) can build
# objects. We grant a focused set of CREATE privileges rather than ALL.
resource "snowflake_grant_privileges_to_account_role" "schema_create_write" {
  for_each = local.write_pairs

  account_role_name = snowflake_account_role.roles[each.value.role].name
  privileges = [
    "USAGE",
    "CREATE TABLE",
    "CREATE VIEW",
    "CREATE MATERIALIZED VIEW",
    "CREATE DYNAMIC TABLE",
    "CREATE STAGE",
    "CREATE FILE FORMAT",
    "CREATE SEQUENCE",
    "CREATE FUNCTION",
    "CREATE PROCEDURE",
  ]
  on_schema {
    schema_name = "\"${snowflake_database.claims.name}\".\"${each.value.schema}\""
  }
  depends_on = [snowflake_schema.schemas]
}

# --- (c) SELECT on existing + FUTURE tables for READ roles ------------------
# FUTURE grants ensure dbt-created tables are automatically readable by analyst/
# MCP/CI without re-running Terraform. Managed-access schemas require the schema
# owner (CLAIMS_SYSADMIN, via SYSADMIN) to issue these — handled by provider role.
resource "snowflake_grant_privileges_to_account_role" "select_future_tables" {
  for_each = local.read_pairs

  account_role_name = snowflake_account_role.roles[each.value.role].name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = "\"${snowflake_database.claims.name}\".\"${each.value.schema}\""
    }
  }
  depends_on = [snowflake_schema.schemas]
}

resource "snowflake_grant_privileges_to_account_role" "select_future_views" {
  for_each = local.read_pairs

  account_role_name = snowflake_account_role.roles[each.value.role].name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "VIEWS"
      in_schema          = "\"${snowflake_database.claims.name}\".\"${each.value.schema}\""
    }
  }
  depends_on = [snowflake_schema.schemas]
}

# --- (c') WRITE (DML) on existing + FUTURE tables for WRITE roles -----------
resource "snowflake_grant_privileges_to_account_role" "write_future_tables" {
  for_each = local.write_pairs

  account_role_name = snowflake_account_role.roles[each.value.role].name
  # Producers need full DML + SELECT on their own tables.
  privileges = ["SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = "\"${snowflake_database.claims.name}\".\"${each.value.schema}\""
    }
  }
  depends_on = [snowflake_schema.schemas]
}

# --- (d) WAREHOUSE USAGE: each role only on its dedicated warehouse ---------
resource "snowflake_grant_privileges_to_account_role" "warehouse_usage" {
  for_each = local.role_warehouse

  account_role_name = snowflake_account_role.roles[each.key].name
  privileges        = ["USAGE", "OPERATE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.warehouses[each.value].name
  }
}

# =============================================================================
# INTERNAL STAGES (one per source feed, all in RAW)
# -----------------------------------------------------------------------------
# Snowflake INTERNAL stages. Data is PUT into these stages and COPY INTO bronze
# tables.
# PRODUCTION HARDENING:
#   - Snowflake-managed encryption is applied automatically to internal stages.
#   - Restrict stage access to the LOADER role (write) and TRANSFORMER/CI (read)
#     via grants below.
# =============================================================================
resource "snowflake_stage" "raw_feeds" {
  for_each = toset(local.source_feeds)

  name     = "STG_${upper(each.value)}"
  database = snowflake_database.claims.name
  schema   = "RAW"
  comment  = "${local.common_comment} | internal stage for ${each.value} feed"

  # Default file format reference for NDJSON ingestion.
  file_format = "FORMAT_NAME = \"${snowflake_database.claims.name}\".\"RAW\".\"${snowflake_file_format.ndjson.name}\""

  depends_on = [
    snowflake_schema.schemas,
    snowflake_file_format.ndjson,
  ]
}

# Stage privileges: LOADER reads+writes stages; TRANSFORMER/CI read for COPY.
resource "snowflake_grant_privileges_to_account_role" "stage_loader" {
  for_each = snowflake_stage.raw_feeds

  account_role_name = snowflake_account_role.roles["CLAIMS_LOADER"].name
  privileges        = ["READ", "WRITE"]
  on_schema_object {
    object_type = "STAGE"
    object_name = "\"${each.value.database}\".\"${each.value.schema}\".\"${each.value.name}\""
  }
}

resource "snowflake_grant_privileges_to_account_role" "stage_readers" {
  # TRANSFORMER and CI may READ stages to COPY INTO bronze.
  for_each = {
    for pair in setproduct(["CLAIMS_TRANSFORMER", "CLAIMS_CI"], local.source_feeds) :
    "${pair[0]}|${pair[1]}" => { role = pair[0], feed = pair[1] }
  }

  account_role_name = snowflake_account_role.roles[each.value.role].name
  privileges        = ["READ"]
  on_schema_object {
    object_type = "STAGE"
    object_name = "\"${snowflake_database.claims.name}\".\"RAW\".\"STG_${upper(each.value.feed)}\""
  }
  depends_on = [snowflake_stage.raw_feeds]
}

# =============================================================================
# FILE FORMATS (in RAW)
# =============================================================================

# NDJSON: newline-delimited JSON. One object per line, so strip_outer_array is
# false (there is no outer array to strip). STRIP_NULL_VALUES kept false to
# preserve explicit nulls for auditing.
resource "snowflake_file_format" "ndjson" {
  name        = "FF_NDJSON"
  database    = snowflake_database.claims.name
  schema      = "RAW"
  format_type = "JSON"
  comment     = "${local.common_comment} | NDJSON ingestion format"

  strip_outer_array   = false
  strip_null_values   = false
  compression         = "AUTO"
  # Tolerate trailing whitespace / allow duplicate keys handling defaults.
  allow_duplicate     = false

  depends_on = [snowflake_schema.schemas]
}

# CSV for dbt seeds / reference data.
resource "snowflake_file_format" "csv_seed" {
  name        = "FF_CSV_SEED"
  database    = snowflake_database.claims.name
  schema      = "RAW"
  format_type = "CSV"
  comment     = "${local.common_comment} | CSV format for seed/reference loads"

  field_delimiter              = ","
  skip_header                  = 1
  field_optionally_enclosed_by = "\""
  null_if                      = ["", "NULL", "null"]
  empty_field_as_null          = true
  compression                  = "AUTO"
  encoding                     = "UTF8"

  depends_on = [snowflake_schema.schemas]
}

# =============================================================================
# OPTIONAL SERVICE USERS  (guarded by var.create_service_users)
# -----------------------------------------------------------------------------
# Non-human users for automation. KEY-PAIR AUTH ONLY (rsa_public_key). The
# public key below is a PLACEHOLDER — in production, supply the real key via a
# variable sourced from a secrets manager, and rotate using RSA_PUBLIC_KEY_2.
#
# SECRET PLACEHOLDER NOTE:
#   - The corresponding PRIVATE keys live in your secrets manager / vault, NOT
#     in Terraform. Reference Snowflake SECRET objects for any external
#     integration credentials (created as placeholders / out-of-band).
#   - Each service user is granted exactly one functional role as its DEFAULT
#     ROLE, enforcing least privilege.
# =============================================================================

# Placeholder public keys. Replace via TF_VAR-driven inputs in real deployments.
locals {
  placeholder_rsa_public_key = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA_PLACEHOLDER_REPLACE_ME"
}

resource "snowflake_user" "mcp_service_user" {
  count = var.create_service_users ? 1 : 0

  name         = "CLAIMS_MCP_SERVICE_USER"
  login_name   = "CLAIMS_MCP_SERVICE_USER"
  comment      = "${local.common_comment} | MCP read-only service user (key-pair auth)"
  disabled     = false

  # Key-pair auth only. No password is set. Rotate via rsa_public_key_2.
  rsa_public_key = local.placeholder_rsa_public_key

  default_role      = snowflake_account_role.roles["CLAIMS_MCP_READER"].name
  default_warehouse = snowflake_warehouse.warehouses["WH_CLAIMS_MCP"].name
  default_namespace = "${snowflake_database.claims.name}.GOLD"

  # PRODUCTION HARDENING: attach a user-level NETWORK POLICY allow-listing the
  # MCP server egress IPs (network_policy = snowflake_network_policy.mcp.name).
}

resource "snowflake_user" "ci_service_user" {
  count = var.create_service_users ? 1 : 0

  name         = "CLAIMS_CI_SERVICE_USER"
  login_name   = "CLAIMS_CI_SERVICE_USER"
  comment      = "${local.common_comment} | CI pipeline service user (key-pair auth)"
  disabled     = false

  rsa_public_key = local.placeholder_rsa_public_key

  default_role      = snowflake_account_role.roles["CLAIMS_CI"].name
  default_warehouse = snowflake_warehouse.warehouses["WH_CLAIMS_CI"].name
  default_namespace = snowflake_database.claims.name

  # PRODUCTION HARDENING: network policy allow-listing CI runner egress IPs.
}

# Assign each service user its functional role (granting role TO the user).
resource "snowflake_grant_account_role" "mcp_user_role" {
  count = var.create_service_users ? 1 : 0

  role_name = snowflake_account_role.roles["CLAIMS_MCP_READER"].name
  user_name = snowflake_user.mcp_service_user[0].name
}

resource "snowflake_grant_account_role" "ci_user_role" {
  count = var.create_service_users ? 1 : 0

  role_name = snowflake_account_role.roles["CLAIMS_CI"].name
  user_name = snowflake_user.ci_service_user[0].name
}

# =============================================================================
# SECRET PLACEHOLDERS
# -----------------------------------------------------------------------------
# Real secrets (API keys for any future integration, etc.) should be created as
# Snowflake SECRET objects and referenced by name. We do NOT store secret values
# in Terraform/state. Example (commented placeholder):
#
# resource "snowflake_secret_with_generic_string" "example_integration" {
#   name          = "CLAIMS_EXTERNAL_API_SECRET"
#   database      = snowflake_database.claims.name
#   schema        = "CONTROL"
#   secret_string = var.example_api_secret  # sourced from vault via TF_VAR
# }
# =============================================================================
