# =============================================================================
# variables.tf (root)
# -----------------------------------------------------------------------------
# Root-level input variables. Environment-specific values are supplied via
# terraform/environments/<env>.tfvars. Sensitive values should be supplied via
# TF_VAR_* environment variables or a secrets manager, never committed.
# =============================================================================

# -----------------------------------------------------------------------------
# Environment selection
# -----------------------------------------------------------------------------
variable "environment" {
  description = "Deployment environment. Drives database naming and sizing. One of: dev, prod."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be one of: dev, prod."
  }
}

variable "database_name" {
  description = <<-EOT
    Override for the managed database name. If empty, the name is derived from
    environment as CLAIMS_DEV / CLAIMS_PROD. Leave empty to use the convention.
  EOT
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Warehouse sizing
# -----------------------------------------------------------------------------
# Map of logical warehouse -> Snowflake size. Sized per environment via tfvars.
# Keys MUST match the warehouse set defined in the module.
variable "warehouse_sizes" {
  description = "Map of logical warehouse name to Snowflake warehouse size (e.g. XSMALL, SMALL, MEDIUM)."
  type        = map(string)
  default = {
    WH_CLAIMS_LOAD      = "XSMALL"
    WH_CLAIMS_TRANSFORM = "XSMALL"
    WH_CLAIMS_ANALYST   = "XSMALL"
    WH_CLAIMS_CI        = "XSMALL"
    WH_CLAIMS_MCP       = "XSMALL"
  }
}

variable "default_warehouse_size" {
  description = "Fallback warehouse size used when a warehouse is not present in warehouse_sizes."
  type        = string
  default     = "XSMALL"
}

variable "auto_suspend_seconds" {
  description = "Seconds of idle time before a warehouse auto-suspends. Lower = cheaper (cold starts); higher = warmer."
  type        = number
  default     = 60
}

# -----------------------------------------------------------------------------
# Snowflake connection
# -----------------------------------------------------------------------------
variable "snowflake_account_name" {
  description = "Snowflake account name / locator (the part after the org, e.g. XY12345)."
  type        = string
}

variable "snowflake_organization_name" {
  description = "Snowflake organization name (e.g. MYORG)."
  type        = string
}

variable "snowflake_user" {
  description = "Snowflake login name used by Terraform (a dedicated automation user is recommended)."
  type        = string
}

variable "snowflake_role" {
  description = <<-EOT
    Role Terraform assumes for object creation. Use the least-privileged role
    capable of creating databases/warehouses/schemas (typically SYSADMIN).
    Role & grant management may use SECURITYADMIN via an aliased provider.
    ACCOUNTADMIN is discouraged as the default running role.
  EOT
  type        = string
  default     = "SYSADMIN"
}

variable "snowflake_private_key_path" {
  description = "Filesystem path to the PEM private key for key-pair (SNOWFLAKE_JWT) auth. Preferred over passwords."
  type        = string
  sensitive   = true
}

variable "snowflake_private_key_passphrase" {
  description = "Passphrase for an encrypted private key, if applicable. Leave empty for an unencrypted key."
  type        = string
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Service users
# -----------------------------------------------------------------------------
variable "create_service_users" {
  description = <<-EOT
    Whether to create non-human service users (CLAIMS_MCP_SERVICE_USER,
    CLAIMS_CI_SERVICE_USER). Typically false in dev (developers use their own
    identities) and true in prod. Service users use key-pair auth only.
  EOT
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Tagging / metadata
# -----------------------------------------------------------------------------
variable "tags" {
  description = "Free-form key/value metadata applied as object comments / governance tags where supported."
  type        = map(string)
  default = {
    project    = "snowflake-claims-platform"
    managed_by = "terraform"
    data_class = "synthetic"
  }
}
