# =============================================================================
# providers.tf
# -----------------------------------------------------------------------------
# Terraform + provider configuration for the Snowflake Claims Platform.
#
# Scope reminder: Terraform owns PLATFORM infrastructure & security boundaries
# only (databases, schemas, warehouses, roles, role hierarchy, grants, internal
# stages, file formats, service users, secret placeholders). All transformation
# tables/views are owned by dbt and are intentionally NOT modeled here.
# =============================================================================

terraform {
  # Pin Terraform core. CI should run the same minor version as developers to
  # avoid state-format drift. Bump deliberately, never implicitly.
  required_version = ">= 1.5.0"

  required_providers {
    snowflake = {
      # Official Snowflake-maintained provider.
      source = "snowflakedb/snowflake"
      # Pin to a recent major/minor line. The provider is still evolving toward
      # 1.0; resource names/behaviors change between minors, so pin tightly and
      # upgrade intentionally after reading the changelog & migration guides.
      version = ">= 0.90, < 2.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Backend
  # ---------------------------------------------------------------------------
  # DEMO / LOCAL backend: state lives on the developer machine. Fine for a
  # synthetic, single-operator demo repo.
  #
  # PRODUCTION HARDENING:
  #   - Use a remote backend with state locking + encryption at rest, e.g.:
  #       * Terraform Cloud / HCP Terraform (recommended: locking, RBAC, audit).
  #       * S3 + DynamoDB lock table (if on AWS) or GCS, with SSE/KMS.
  #   - Snowflake itself can host an OBJECT-storage-backed remote state via an
  #     S3-compatible external stage, but prefer a purpose-built backend.
  #   - State contains sensitive values (account ids, grants). Restrict access,
  #     enable versioning, and never commit *.tfstate to git.
  #
  # Example remote backend (commented; enable per environment):
  #
  # backend "s3" {
  #   bucket         = "claims-platform-tfstate"
  #   key            = "snowflake/${terraform.workspace}/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "claims-platform-tflock"
  #   encrypt        = true
  # }
  #
  # For the demo we leave the default local backend (no block = local state).
}

# =============================================================================
# Snowflake provider
# =============================================================================
# Authentication notes (PRODUCTION HARDENING):
#   - KEY-PAIR AUTH IS PREFERRED for both human-admin automation and service
#     users. It avoids password handling, supports rotation, and is required
#     for non-interactive CI. We wire the private key via a file path variable.
#   - Password / username auth and browser SSO are intentionally avoided for
#     automation. If a human runs Terraform interactively, prefer
#     `authenticator = "externalbrowser"` with SSO + MFA instead of a password.
#   - The role used by Terraform should be the LEAST privileged role able to
#     create the managed objects. Typically SYSADMIN for databases/warehouses/
#     schemas, with SECURITYADMIN used for role + grant management. ACCOUNTADMIN
#     should NOT be the default running role; grant the running role only what
#     it needs (e.g. CREATE DATABASE, CREATE WAREHOUSE, MANAGE GRANTS).
#   - Never hardcode secrets. All sensitive inputs come from variables which in
#     turn should be supplied via environment variables (TF_VAR_*) or a secrets
#     manager, never committed tfvars.
#
provider "snowflake" {
  account_name      = var.snowflake_account_name      # e.g. "XY12345"
  organization_name = var.snowflake_organization_name # e.g. "MYORG"
  user              = var.snowflake_user

  # Role the provider assumes for object creation. For grant/role management
  # you may run a second aliased provider as SECURITYADMIN (see below) or grant
  # MANAGE GRANTS to this role. Default kept configurable via variable.
  role = var.snowflake_role

  # Key-pair authentication (preferred). The private key is read from a file
  # path so the key material never lands in tfvars/state inputs directly.
  # If the key is encrypted, also supply var.snowflake_private_key_passphrase.
  authenticator             = "SNOWFLAKE_JWT"
  private_key               = file(var.snowflake_private_key_path)
  # private_key_passphrase  = var.snowflake_private_key_passphrase

  # Default warehouse the session uses for provider operations that need compute
  # (most DDL does not). Kept small/transient.
  # warehouse = var.warehouse_for_admin

  # Recommended provider behaviors:
  preview_features_enabled = []
}

# -----------------------------------------------------------------------------
# OPTIONAL: dedicated SECURITYADMIN-scoped provider alias for role + grant
# management, to keep a clean separation between object ownership (SYSADMIN)
# and access management (SECURITYADMIN). The module can be passed this aliased
# provider for its role/grant resources. Enable in production hardening.
# -----------------------------------------------------------------------------
# provider "snowflake" {
#   alias             = "security_admin"
#   account_name      = var.snowflake_account_name
#   organization_name = var.snowflake_organization_name
#   user              = var.snowflake_user
#   role              = "SECURITYADMIN"
#   authenticator     = "SNOWFLAKE_JWT"
#   private_key       = file(var.snowflake_private_key_path)
# }
