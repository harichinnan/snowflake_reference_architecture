/* =============================================================================
   03_control_tables.sql
   DCM declarative definitions for the CONTROL schema.
   -----------------------------------------------------------------------------
   Replaces the imperative CREATE TABLEs in
   snowflake/setup/005_create_control_tables.sql.

   These are DCM-declarative DEFINE TABLE statements (CREATE-OR-ALTER form). No
   CREATE / IF NOT EXISTS / OR REPLACE; every object is fully qualified with the
   {{ database }} Jinja variable (CLAIMS_DEV / CLAIMS_PROD). DML (the
   PIPELINE_CONFIG / DATA_CONTRACT seed MERGEs) is intentionally omitted — DCM
   manages object DDL only.
   ============================================================================= */

DEFINE TABLE {{ database }}.CONTROL.PIPELINE_CONFIG (
  pipeline_name              STRING       NOT NULL COMMENT 'Logical pipeline id, e.g. claim_event.',
  source_system             STRING       COMMENT 'Originating source system code.',
  target_table              STRING       COMMENT 'Fully-qualified bronze landing target.',
  load_strategy             STRING       COMMENT 'incremental | full_refresh | append.',
  watermark_column          STRING       COMMENT 'Column used for incremental high-water mark.',
  lookback_days             NUMBER       COMMENT 'Days re-scanned each run to catch corrections.',
  late_arrival_days         NUMBER       COMMENT 'Window for accepting late-arriving events.',
  dedupe_key_expression     STRING       COMMENT 'SQL expr defining the dedupe/business grain key.',
  expected_arrival_frequency STRING      COMMENT 'e.g. hourly | daily.',
  max_allowed_lag_hours     NUMBER       COMMENT 'Freshness SLA: max acceptable source-to-ingest lag.',
  is_active                 BOOLEAN      DEFAULT TRUE COMMENT 'Disable a pipeline without deleting config.',
  CONSTRAINT pk_pipeline_config PRIMARY KEY (pipeline_name)
)
COMMENT = 'Declarative per-pipeline load configuration (drives dbt + orchestration).';

DEFINE TABLE {{ database }}.CONTROL.PIPELINE_RUN (
  pipeline_run_id    STRING        NOT NULL COMMENT 'Unique run id (UUID).',
  pipeline_name      STRING        COMMENT 'FK -> PIPELINE_CONFIG.pipeline_name.',
  environment        STRING        COMMENT 'DEV | PROD.',
  run_status         STRING        COMMENT 'RUNNING | SUCCESS | FAILED | SKIPPED.',
  started_at         TIMESTAMP_NTZ COMMENT 'Run start.',
  completed_at       TIMESTAMP_NTZ COMMENT 'Run end.',
  rows_loaded        NUMBER        COMMENT 'Rows read from source this run.',
  rows_inserted      NUMBER        COMMENT 'New rows written.',
  rows_updated       NUMBER        COMMENT 'Existing rows updated (merge).',
  rows_quarantined   NUMBER        COMMENT 'Rows routed to quarantine.',
  max_watermark_seen TIMESTAMP_NTZ COMMENT 'Highest watermark observed this run.',
  error_message      STRING        COMMENT 'Failure detail if run_status=FAILED.',
  git_sha            STRING        COMMENT 'Commit SHA that produced this run.',
  dbt_invocation_id  STRING        COMMENT 'dbt invocation id for artifact correlation.',
  CONSTRAINT pk_pipeline_run PRIMARY KEY (pipeline_run_id)
)
COMMENT = 'Per-execution run ledger; traceable to git + dbt artifacts.';

DEFINE TABLE {{ database }}.CONTROL.WATERMARK_STATE (
  pipeline_name             STRING        NOT NULL,
  source_system            STRING,
  target_table             STRING,
  last_successful_watermark TIMESTAMP_NTZ COMMENT 'Latest committed high-water mark.',
  prior_successful_watermark TIMESTAMP_NTZ COMMENT 'Previous mark (rollback reference).',
  lookback_start_watermark  TIMESTAMP_NTZ COMMENT 'Effective scan start = mark - lookback_days.',
  updated_at               TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_watermark_state PRIMARY KEY (pipeline_name)
)
COMMENT = 'Incremental high-water marks per pipeline (current + prior + lookback start).';

DEFINE TABLE {{ database }}.CONTROL.LOAD_BATCH (
  batch_id          STRING        NOT NULL,
  source_system    STRING,
  source_file_name STRING        COMMENT 'Staged file name (METADATA$FILENAME).',
  file_arrival_ts  TIMESTAMP_NTZ COMMENT 'When the file landed on the stage.',
  source_extract_ts TIMESTAMP_NTZ COMMENT 'Extract timestamp asserted by the producer.',
  file_hash        STRING        COMMENT 'Content hash for idempotency / dup detection.',
  file_row_count   NUMBER        COMMENT 'Expected row count for reconciliation.',
  load_status      STRING        COMMENT 'PENDING | LOADED | FAILED | SKIPPED_DUP.',
  loaded_at        TIMESTAMP_NTZ COMMENT 'When COPY INTO completed.',
  CONSTRAINT pk_load_batch PRIMARY KEY (batch_id)
)
COMMENT = 'Per-file/batch load ledger; supports idempotent reloads and reconciliation.';

DEFINE TABLE {{ database }}.CONTROL.SCHEMA_VERSION (
  source_system  STRING        NOT NULL,
  schema_name    STRING        NOT NULL,
  schema_version STRING        NOT NULL,
  effective_from TIMESTAMP_NTZ,
  effective_to   TIMESTAMP_NTZ,
  json_schema    VARIANT       COMMENT 'JSON Schema document for this version.',
  is_current     BOOLEAN       DEFAULT TRUE,
  CONSTRAINT pk_schema_version PRIMARY KEY (source_system, schema_name, schema_version)
)
COMMENT = 'Versioned source JSON schemas (SCD2). Drives contract validation.';

DEFINE TABLE {{ database }}.CONTROL.DATA_CONTRACT (
  contract_id          STRING        NOT NULL,
  source_system       STRING,
  object_name         STRING        COMMENT 'Source object / feed this contract governs.',
  schema_version      STRING        COMMENT 'FK -> SCHEMA_VERSION.schema_version.',
  required_fields     VARIANT       COMMENT 'Array of fields that MUST be present.',
  optional_fields     VARIANT       COMMENT 'Array of optional fields.',
  primary_business_keys VARIANT     COMMENT 'Array of business-key fields (grain).',
  expected_grain      STRING        COMMENT 'Human-readable grain statement.',
  effective_from      TIMESTAMP_NTZ,
  effective_to        TIMESTAMP_NTZ,
  is_current          BOOLEAN       DEFAULT TRUE,
  CONSTRAINT pk_data_contract PRIMARY KEY (contract_id)
)
COMMENT = 'Producer/consumer data contracts per source object (validated at ingest).';

DEFINE TABLE {{ database }}.CONTROL.REPROCESSING_LEDGER (
  reprocess_batch_id STRING        NOT NULL,
  original_batch_id  STRING        COMMENT 'Batch being reprocessed (FK -> LOAD_BATCH).',
  pipeline_name      STRING,
  reprocess_reason   STRING,
  reprocess_scope    STRING        COMMENT 'e.g. date range / batch / full.',
  requested_by       STRING,
  approved_by        STRING        COMMENT 'Four-eyes: must differ from requested_by.',
  started_at         TIMESTAMP_NTZ,
  completed_at       TIMESTAMP_NTZ,
  status             STRING        COMMENT 'REQUESTED | APPROVED | RUNNING | DONE | FAILED.',
  rows_reprocessed   NUMBER,
  validation_status  STRING        COMMENT 'PASS | FAIL after post-reprocess checks.',
  CONSTRAINT pk_reprocessing_ledger PRIMARY KEY (reprocess_batch_id)
)
COMMENT = 'Audited reprocessing/backfill requests with approval + validation.';

DEFINE TABLE {{ database }}.CONTROL.PIPELINE_FRESHNESS_STATUS (
  pipeline_name         STRING        NOT NULL,
  source_system        STRING,
  latest_source_extract_ts TIMESTAMP_NTZ COMMENT 'Newest source extract observed.',
  latest_ingest_ts     TIMESTAMP_NTZ COMMENT 'Newest ingest into bronze.',
  max_allowed_lag_hours NUMBER       COMMENT 'SLA threshold (from PIPELINE_CONFIG).',
  freshness_status      STRING       COMMENT 'FRESH | STALE | BREACHED.',
  alert_severity        STRING       COMMENT 'NONE | WARN | CRITICAL.',
  checked_at            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_pipeline_freshness PRIMARY KEY (pipeline_name)
)
COMMENT = 'Computed freshness/lag SLA status per pipeline (drives alerts).';

DEFINE TABLE {{ database }}.CONTROL.SEMANTIC_METRIC_REGISTRY (
  metric_name        STRING        NOT NULL,
  business_definition STRING,
  calculation_sql    STRING        COMMENT 'Reference SQL for the metric.',
  grain              STRING,
  owner              STRING,
  certified_status   STRING        COMMENT 'DRAFT | REVIEW | CERTIFIED | DEPRECATED.',
  source_model       STRING        COMMENT 'Backing GOLD/SEMANTIC model.',
  allowed_dimensions VARIANT       COMMENT 'Array of valid slicing dimensions.',
  default_filters    VARIANT       COMMENT 'Default filter predicates.',
  created_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_semantic_metric_registry PRIMARY KEY (metric_name)
)
COMMENT = 'Control-side registry of certified metrics (ownership + lineage governance).';
