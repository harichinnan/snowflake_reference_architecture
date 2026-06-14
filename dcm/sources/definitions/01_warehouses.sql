-- =============================================================================
-- 01_warehouses.sql  ::  DCM declarative warehouse definitions (account-level)
-- Replaces snowflake/setup/002_create_warehouses.sql.
-- Sizes/auto_suspend come from manifest templating (DEV vs PROD).
-- =============================================================================

DEFINE WAREHOUSE WH_CLAIMS_LOAD
  WITH
    warehouse_size       = '{{ default_wh_size }}'
    auto_suspend         = {{ auto_suspend }}
    auto_resume          = TRUE
    initially_suspended  = TRUE
    statement_timeout_in_seconds = {{ statement_timeout }}
    comment = 'Ingestion: PUT to internal stage + COPY INTO RAW/BRONZE.';

DEFINE WAREHOUSE WH_CLAIMS_TRANSFORM
  WITH
    warehouse_size       = '{{ transform_wh_size }}'
    auto_suspend         = {{ auto_suspend }}
    auto_resume          = TRUE
    initially_suspended  = TRUE
    statement_timeout_in_seconds = {{ statement_timeout }}
    comment = 'dbt transforms BRONZE->SILVER->GOLD (heaviest compute).';

DEFINE WAREHOUSE WH_CLAIMS_ANALYST
  WITH
    warehouse_size       = '{{ default_wh_size }}'
    auto_suspend         = {{ auto_suspend }}
    auto_resume          = TRUE
    initially_suspended  = TRUE
    statement_timeout_in_seconds = {{ statement_timeout }}
    comment = 'Ad-hoc BI / Workbook queries on GOLD/SEMANTIC.';

DEFINE WAREHOUSE WH_CLAIMS_CI
  WITH
    warehouse_size       = '{{ default_wh_size }}'
    auto_suspend         = {{ auto_suspend }}
    auto_resume          = TRUE
    initially_suspended  = TRUE
    statement_timeout_in_seconds = {{ statement_timeout }}
    comment = 'CI builds in ephemeral schemas.';

DEFINE WAREHOUSE WH_CLAIMS_MCP
  WITH
    warehouse_size       = '{{ default_wh_size }}'
    auto_suspend         = {{ auto_suspend }}
    auto_resume          = TRUE
    initially_suspended  = TRUE
    statement_timeout_in_seconds = {{ statement_timeout }}
    comment = 'Cortex Analyst/Search + MCP read-only access layer.';
