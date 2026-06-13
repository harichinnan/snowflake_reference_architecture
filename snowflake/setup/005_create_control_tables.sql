/* =============================================================================
   005_create_control_tables.sql
   snowflake-claims-platform :: CONTROL schema (pipeline orchestration metadata)
   -----------------------------------------------------------------------------
   These are INFRASTRUCTURE tables (owned by setup, NOT by dbt). dbt reads/writes
   rows into them at runtime (run rows, watermarks, batches), but the platform
   defines their shape here so they exist before any pipeline executes.

   Synthetic platform — rows describe synthetic loads; no real PHI.

   TABLES
     PIPELINE_CONFIG            : declarative per-pipeline load configuration.
     PIPELINE_RUN               : one row per dbt/orchestrated execution.
     WATERMARK_STATE            : incremental high-water marks per pipeline.
     LOAD_BATCH                 : one row per ingested file/batch (COPY INTO).
     SCHEMA_VERSION             : evolving source JSON schema versions.
     DATA_CONTRACT              : producer/consumer contract per source object.
     REPROCESSING_LEDGER        : audited backfill/reprocess requests.
     PIPELINE_FRESHNESS_STATUS  : computed freshness/lag SLA status.
     SEMANTIC_METRIC_REGISTRY   : control-side registry of certified metrics.

   RUN AS: CLAIMS_SYSADMIN. Parameterised on $claims_db. IDEMPOTENT.
   ============================================================================= */

SET claims_db = 'CLAIMS_DEV';   -- override: -D claims_db=CLAIMS_PROD

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);
USE SCHEMA CONTROL;

/* -----------------------------------------------------------------------------
   PIPELINE_CONFIG — declarative config that drives every pipeline.
   A new feed is onboarded by INSERTing a row here, not by editing code.
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS PIPELINE_CONFIG (
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
) COMMENT = 'Declarative per-pipeline load configuration (drives dbt + orchestration).';

/* -----------------------------------------------------------------------------
   PIPELINE_RUN — execution ledger. One row per run; updated on completion.
   git_sha + dbt_invocation_id make every run traceable to code + artifacts.
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS PIPELINE_RUN (
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
) COMMENT = 'Per-execution run ledger; traceable to git + dbt artifacts.';

/* -----------------------------------------------------------------------------
   WATERMARK_STATE — current/prior incremental marks. Keeping the prior mark and
   the lookback start enables safe replays and "what window did we actually scan".
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS WATERMARK_STATE (
  pipeline_name             STRING        NOT NULL,
  source_system            STRING,
  target_table             STRING,
  last_successful_watermark TIMESTAMP_NTZ COMMENT 'Latest committed high-water mark.',
  prior_successful_watermark TIMESTAMP_NTZ COMMENT 'Previous mark (rollback reference).',
  lookback_start_watermark  TIMESTAMP_NTZ COMMENT 'Effective scan start = mark - lookback_days.',
  updated_at               TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_watermark_state PRIMARY KEY (pipeline_name)
) COMMENT = 'Incremental high-water marks per pipeline (current + prior + lookback start).';

/* -----------------------------------------------------------------------------
   LOAD_BATCH — one row per file/batch landed via COPY INTO. file_hash enables
   idempotent loads (skip an already-loaded file); file_row_count reconciles.
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS LOAD_BATCH (
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
) COMMENT = 'Per-file/batch load ledger; supports idempotent reloads and reconciliation.';

/* -----------------------------------------------------------------------------
   SCHEMA_VERSION — tracks evolving source JSON schemas (SCD2 via is_current).
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS SCHEMA_VERSION (
  source_system  STRING        NOT NULL,
  schema_name    STRING        NOT NULL,
  schema_version STRING        NOT NULL,
  effective_from TIMESTAMP_NTZ,
  effective_to   TIMESTAMP_NTZ,
  json_schema    VARIANT       COMMENT 'JSON Schema document for this version.',
  is_current     BOOLEAN       DEFAULT TRUE,
  CONSTRAINT pk_schema_version PRIMARY KEY (source_system, schema_name, schema_version)
) COMMENT = 'Versioned source JSON schemas (SCD2). Drives contract validation.';

/* -----------------------------------------------------------------------------
   DATA_CONTRACT — the producer/consumer contract per source object. Required vs
   optional fields, business keys, and grain are validated against incoming data.
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS DATA_CONTRACT (
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
) COMMENT = 'Producer/consumer data contracts per source object (validated at ingest).';

/* -----------------------------------------------------------------------------
   REPROCESSING_LEDGER — audited backfills. requested_by/approved_by enforce a
   four-eyes control before a destructive reprocess runs.
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS REPROCESSING_LEDGER (
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
) COMMENT = 'Audited reprocessing/backfill requests with approval + validation.';

/* -----------------------------------------------------------------------------
   PIPELINE_FRESHNESS_STATUS — computed freshness/lag SLA evaluation.
   Populated by a freshness check task/model; drives alerting.
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS PIPELINE_FRESHNESS_STATUS (
  pipeline_name         STRING        NOT NULL,
  source_system        STRING,
  latest_source_extract_ts TIMESTAMP_NTZ COMMENT 'Newest source extract observed.',
  latest_ingest_ts     TIMESTAMP_NTZ COMMENT 'Newest ingest into bronze.',
  max_allowed_lag_hours NUMBER       COMMENT 'SLA threshold (from PIPELINE_CONFIG).',
  freshness_status      STRING       COMMENT 'FRESH | STALE | BREACHED.',
  alert_severity        STRING       COMMENT 'NONE | WARN | CRITICAL.',
  checked_at            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_pipeline_freshness PRIMARY KEY (pipeline_name)
) COMMENT = 'Computed freshness/lag SLA status per pipeline (drives alerts).';

/* -----------------------------------------------------------------------------
   SEMANTIC_METRIC_REGISTRY (CONTROL-side) — operational registry of certified
   metrics. (SEMANTIC schema also holds a presentation-facing METRIC_REGISTRY;
   this control copy governs lineage/ownership.)
   --------------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS SEMANTIC_METRIC_REGISTRY (
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
) COMMENT = 'Control-side registry of certified metrics (ownership + lineage governance).';

/* =============================================================================
   SEED DATA — one PIPELINE_CONFIG row per feed + a couple of DATA_CONTRACTs.
   MERGE makes seeding idempotent (re-running updates in place, no dup PKs).
   ============================================================================= */

-- PIPELINE_CONFIG seed (claim/eligibility/provider/pharmacy/adjudication).
MERGE INTO PIPELINE_CONFIG t
USING (
  SELECT * FROM VALUES
    ('claim_event',        'CLAIMS_CORE', 'BRONZE.BR_RAW_CLAIM_EVENT',        'incremental', 'business_event_ts', 7, 30, 'natural_key || ''|'' || payload_hash', 'hourly', 6),
    ('eligibility_event',  'ELIG_SYS',    'BRONZE.BR_RAW_ELIGIBILITY_EVENT',  'incremental', 'business_event_ts', 7, 30, 'natural_key || ''|'' || payload_hash', 'daily',  24),
    ('provider_event',     'PROVIDER_MD', 'BRONZE.BR_RAW_PROVIDER_EVENT',     'incremental', 'business_event_ts', 7, 30, 'natural_key || ''|'' || payload_hash', 'daily',  48),
    ('pharmacy_event',     'RX_HUB',      'BRONZE.BR_RAW_PHARMACY_EVENT',     'incremental', 'business_event_ts', 7, 30, 'natural_key || ''|'' || payload_hash', 'hourly', 6),
    ('adjudication_event', 'ADJUD_ENGINE','BRONZE.BR_RAW_ADJUDICATION_EVENT', 'incremental', 'business_event_ts', 7, 30, 'natural_key || ''|'' || payload_hash', 'hourly', 6)
  AS s(pipeline_name, source_system, target_table, load_strategy, watermark_column,
       lookback_days, late_arrival_days, dedupe_key_expression, expected_arrival_frequency, max_allowed_lag_hours)
) s
ON t.pipeline_name = s.pipeline_name
WHEN MATCHED THEN UPDATE SET
  source_system = s.source_system, target_table = s.target_table, load_strategy = s.load_strategy,
  watermark_column = s.watermark_column, lookback_days = s.lookback_days, late_arrival_days = s.late_arrival_days,
  dedupe_key_expression = s.dedupe_key_expression, expected_arrival_frequency = s.expected_arrival_frequency,
  max_allowed_lag_hours = s.max_allowed_lag_hours, is_active = TRUE
WHEN NOT MATCHED THEN INSERT
  (pipeline_name, source_system, target_table, load_strategy, watermark_column, lookback_days,
   late_arrival_days, dedupe_key_expression, expected_arrival_frequency, max_allowed_lag_hours, is_active)
  VALUES (s.pipeline_name, s.source_system, s.target_table, s.load_strategy, s.watermark_column,
          s.lookback_days, s.late_arrival_days, s.dedupe_key_expression, s.expected_arrival_frequency,
          s.max_allowed_lag_hours, TRUE);

-- DATA_CONTRACT seed (claim + adjudication examples).
MERGE INTO DATA_CONTRACT t
USING (
  SELECT
    'DC_CLAIM_V1' AS contract_id, 'CLAIMS_CORE' AS source_system, 'claim_event' AS object_name, 'v1' AS schema_version,
    ARRAY_CONSTRUCT('claim_id','member_id','provider_id','event_type','event_ts','service_date','billed_amount') AS required_fields,
    ARRAY_CONSTRUCT('diagnosis_codes','procedure_codes','place_of_service') AS optional_fields,
    ARRAY_CONSTRUCT('claim_id') AS primary_business_keys,
    'one row per claim_id per event_ts' AS expected_grain,
    '2024-01-01'::timestamp_ntz AS effective_from, NULL::timestamp_ntz AS effective_to, TRUE AS is_current
  UNION ALL
  SELECT
    'DC_ADJUD_V1', 'ADJUD_ENGINE', 'adjudication_event', 'v1',
    ARRAY_CONSTRUCT('claim_id','adjudication_id','event_type','event_ts','paid_amount','allowed_amount','status'),
    ARRAY_CONSTRUCT('denial_reason','adjustment_codes'),
    ARRAY_CONSTRUCT('adjudication_id'),
    'one row per adjudication_id per event_ts',
    '2024-01-01'::timestamp_ntz, NULL::timestamp_ntz, TRUE
) s
ON t.contract_id = s.contract_id
WHEN MATCHED THEN UPDATE SET
  source_system = s.source_system, object_name = s.object_name, schema_version = s.schema_version,
  required_fields = s.required_fields, optional_fields = s.optional_fields,
  primary_business_keys = s.primary_business_keys, expected_grain = s.expected_grain,
  effective_from = s.effective_from, effective_to = s.effective_to, is_current = s.is_current
WHEN NOT MATCHED THEN INSERT
  (contract_id, source_system, object_name, schema_version, required_fields, optional_fields,
   primary_business_keys, expected_grain, effective_from, effective_to, is_current)
  VALUES (s.contract_id, s.source_system, s.object_name, s.schema_version, s.required_fields,
          s.optional_fields, s.primary_business_keys, s.expected_grain, s.effective_from,
          s.effective_to, s.is_current);

/* -----------------------------------------------------------------------------
   GRANTS — transformer/CI write run/watermark/batch rows; analyst reads config.
   --------------------------------------------------------------------------- */
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA CONTROL    TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT, INSERT, UPDATE ON FUTURE TABLES IN SCHEMA CONTROL TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA CONTROL    TO ROLE CLAIMS_CI;
GRANT SELECT, INSERT, UPDATE ON FUTURE TABLES IN SCHEMA CONTROL TO ROLE CLAIMS_CI;
GRANT INSERT, UPDATE ON TABLE LOAD_BATCH TO ROLE CLAIMS_LOADER;
GRANT SELECT          ON TABLE PIPELINE_CONFIG TO ROLE CLAIMS_LOADER;

/* DONE. */
