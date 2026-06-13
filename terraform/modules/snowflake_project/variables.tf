# =============================================================================
# modules/snowflake_project/variables.tf
# -----------------------------------------------------------------------------
# Input variables for the snowflake_project module.
# =============================================================================

variable "environment" {
  description = "Deployment environment (dev|prod). Used for naming/comments."
  type        = string
}

variable "database_name" {
  description = "Fully resolved database name to create (e.g. CLAIMS_DEV / CLAIMS_PROD)."
  type        = string
}

variable "warehouse_sizes" {
  description = "Map of warehouse name -> Snowflake size. Keys must cover the managed warehouse set."
  type        = map(string)
}

variable "default_warehouse_size" {
  description = "Fallback size for a warehouse absent from warehouse_sizes."
  type        = string
  default     = "XSMALL"
}

variable "auto_suspend_seconds" {
  description = "Idle seconds before warehouse auto-suspend."
  type        = number
  default     = 60
}

variable "create_service_users" {
  description = "Create non-human service users (key-pair auth). Guards optional snowflake_user resources."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Metadata applied as comments / governance tags where supported."
  type        = map(string)
  default     = {}
}
