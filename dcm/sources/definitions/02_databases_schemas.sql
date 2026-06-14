-- =============================================================================
-- 02_databases_schemas.sql  ::  DCM database + schema definitions
-- Replaces snowflake/setup/003_create_databases_schemas.sql.
-- {{ database }} = CLAIMS_DEV (DEV target) / CLAIMS_PROD (PROD target).
-- Schemas use fully qualified names (DCM requirement).
-- =============================================================================

DEFINE DATABASE {{ database }}
  COMMENT = 'snowflake-claims-platform database (SYNTHETIC claims; no real PHI).';

-- Medallion + governance + Cortex schemas.
DEFINE SCHEMA {{ database }}.RAW                 COMMENT = 'COPY INTO landing + dbt seeds.';
DEFINE SCHEMA {{ database }}.BRONZE              COMMENT = 'Immutable VARIANT payloads + ingest metadata.';
DEFINE SCHEMA {{ database }}.SILVER_CANONICAL    COMMENT = 'Normalized, typed, deduped business entities.';
DEFINE SCHEMA {{ database }}.SILVER_DIMENSIONAL  COMMENT = 'Star schema (facts + conformed dims).';
DEFINE SCHEMA {{ database }}.GOLD                COMMENT = 'Certified metrics / data products.';
DEFINE SCHEMA {{ database }}.CONTROL             COMMENT = 'DCM operational tables (watermarks, batches, SLA).';
DEFINE SCHEMA {{ database }}.AUDIT               COMMENT = 'Run logs, lineage, DQ results, access audit.';
DEFINE SCHEMA {{ database }}.SEMANTIC            COMMENT = 'Semantic models/views + doc tables.';
DEFINE SCHEMA {{ database }}.CORTEX              COMMENT = 'Cortex Search/Analyst/Agent objects.';

-- DBT schema holds the dbt-Projects-on-Snowflake DBT PROJECT object (the object
-- itself is created outside DCM -- see snowflake/setup/013).
DEFINE SCHEMA {{ database }}.DBT                 COMMENT = 'dbt Projects on Snowflake DBT PROJECT object.';
