/* =============================================================================
   07_semantic_tables.sql
   DCM declarative definitions for the SEMANTIC schema doc/reference tables.
   -----------------------------------------------------------------------------
   Replaces ONLY the SEMANTIC doc/reference CREATE TABLEs (section 1) in
   snowflake/setup/012_create_semantic_views.sql:
     METRIC_REGISTRY, DATA_DICTIONARY, PROVIDER_LOOKUP, CLAIMS_RUNBOOK.

   The CLAIMS_SEMANTIC_VIEW semantic view, the MCP_* views, their grants, and all
   seed DML are NOT translated here — they depend on dbt-built GOLD /
   SILVER_DIMENSIONAL models (or are DML) and remain imperative elsewhere.

   DCM-declarative DEFINE TABLE statements (CREATE-OR-ALTER form). No CREATE /
   IF NOT EXISTS / OR REPLACE; every object is fully qualified with the
   {{ database }} Jinja variable (CLAIMS_DEV / CLAIMS_PROD). No DML.
   ============================================================================= */

DEFINE TABLE {{ database }}.SEMANTIC.METRIC_REGISTRY (
  metric_name        STRING        NOT NULL,
  business_definition STRING,
  calculation_sql    STRING,
  grain              STRING,
  owner              STRING,
  certified_status   STRING        COMMENT 'DRAFT | REVIEW | CERTIFIED | DEPRECATED.',
  source_model       STRING,
  allowed_dimensions VARIANT,
  default_filters    VARIANT,
  created_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_metric_registry PRIMARY KEY (metric_name)
)
COMMENT = 'Certified metric definitions (presentation). Backs Cortex metric-doc search. Seeded by semantic/*.sql.';

DEFINE TABLE {{ database }}.SEMANTIC.DATA_DICTIONARY (
  object_name STRING NOT NULL COMMENT 'Schema-qualified object.',
  column_name STRING NOT NULL,
  data_type   STRING,
  description STRING,
  is_pii      BOOLEAN DEFAULT FALSE COMMENT 'Marks columns that would be PII in a real system.',
  created_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_data_dictionary PRIMARY KEY (object_name, column_name)
)
COMMENT = 'Column-level documentation for governed objects. Backs Cortex search. Seeded by semantic/*.sql.';

DEFINE TABLE {{ database }}.SEMANTIC.PROVIDER_LOOKUP (
  provider_id    STRING NOT NULL,
  provider_name  STRING,
  specialty      STRING,
  city           STRING,
  state          STRING,
  network_status STRING COMMENT 'IN_NETWORK | OUT_OF_NETWORK.',
  created_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_provider_lookup PRIMARY KEY (provider_id)
)
COMMENT = 'Synthetic provider directory. Backs CLAIMS_PROVIDER_SEARCH. Seeded by semantic/*.sql.';

DEFINE TABLE {{ database }}.SEMANTIC.CLAIMS_RUNBOOK (
  runbook_id STRING NOT NULL,
  title      STRING,
  category   STRING COMMENT 'INGESTION | DQ | REPROCESSING | FRESHNESS | SECURITY.',
  content    STRING COMMENT 'Runbook body / remediation steps.',
  created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_claims_runbook PRIMARY KEY (runbook_id)
)
COMMENT = 'Operational runbook entries. Backs CLAIMS_DATA_QUALITY_SEARCH. Seeded by semantic/*.sql.';
