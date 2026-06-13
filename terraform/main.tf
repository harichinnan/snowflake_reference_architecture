# =============================================================================
# main.tf (root)
# -----------------------------------------------------------------------------
# Root module: instantiates the snowflake_project module that builds the full
# platform footprint (database, schemas, warehouses, roles, role hierarchy,
# least-privilege grants, internal stages, file formats, optional service users).
#
# Transformation models (tables/views in BRONZE..GOLD) are owned by dbt and are
# intentionally NOT created here.
# =============================================================================

locals {
  # Derive the database name from the environment unless explicitly overridden.
  database_name = var.database_name != "" ? var.database_name : (
    var.environment == "prod" ? "CLAIMS_PROD" : "CLAIMS_DEV"
  )
}

module "snowflake_project" {
  source = "./modules/snowflake_project"

  environment   = var.environment
  database_name = local.database_name

  warehouse_sizes        = var.warehouse_sizes
  default_warehouse_size = var.default_warehouse_size
  auto_suspend_seconds   = var.auto_suspend_seconds

  create_service_users = var.create_service_users

  tags = var.tags

  # If you enable the SECURITYADMIN provider alias in providers.tf, pass it to
  # the module so role/grant resources run under SECURITYADMIN:
  # providers = {
  #   snowflake              = snowflake
  #   snowflake.security_admin = snowflake.security_admin
  # }
}
