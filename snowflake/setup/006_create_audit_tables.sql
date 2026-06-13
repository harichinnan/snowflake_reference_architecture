/* =============================================================================
   006_create_audit_tables.sql
   snowflake-claims-platform :: AUDIT schema + BRONZE landing tables
   -----------------------------------------------------------------------------
   Two groups of INFRASTRUCTURE objects (owned by setup, not dbt):

   A) AUDIT schema observability tables:
        DATA_QUALITY_RESULT  : per-test DQ outcomes (from dbt tests / checks).
        QUARANTINE_RECORD    : rows that failed validation, held for resolution.
        LINEAGE_EVENT        : source->target transformation lineage events.
        MCP_QUERY_LOG        : every Cortex/MCP-generated query (auditability).

   B) BRONZE landing tables (BR_RAW_*):
        These are the COPY INTO TARGETS. The loader lands raw events here FIRST
        (source-faithful, append-only). dbt then runs incremental BRONZE models
        DOWNSTREAM of these landing tables (dbt does not own the landing target;
        it owns the curated bronze/silver/gold models that read from it). We
        create them here because they are ingestion infrastructure that must
        exist before any load can run.

   Synthetic data only — payloads contain NO real PHI. The QUARANTINE_RECORD and
   BR_RAW_* payload VARIANT columns would, in a real system, hold sensitive data
   and MUST be masked + access-restricted (handled by CLAIMS_SECURITY_ADMIN).

   RUN AS: CLAIMS_SYSADMIN. Parameterised on $claims_db. IDEMPOTENT.
   ============================================================================= */

SET claims_db = 'CLAIMS_DEV';   -- override: -D claims_db=CLAIMS_PROD

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);

/* =============================================================================
   A) AUDIT SCHEMA
   ============================================================================= */
USE SCHEMA AUDIT;

/* DATA_QUALITY_RESULT — one row per test execution. sample_failed_rows holds a
   bounded VARIANT sample so triagers can see failures without re-running. */
CREATE TABLE IF NOT EXISTS DATA_QUALITY_RESULT (
  dq_result_id      STRING        NOT NULL,
  pipeline_run_id   STRING        COMMENT 'FK -> CONTROL.PIPELINE_RUN.',
  model_name        STRING        COMMENT 'dbt model / object under test.',
  test_name         STRING        COMMENT 'Test identifier (e.g. not_null_claim_id).',
  severity          STRING        COMMENT 'WARN | ERROR.',
  status            STRING        COMMENT 'PASS | FAIL | SKIPPED.',
  failed_row_count  NUMBER        COMMENT 'Number of rows failing the test.',
  sample_failed_rows VARIANT      COMMENT 'Bounded sample of failing rows (triage).',
  created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_dq_result PRIMARY KEY (dq_result_id)
) COMMENT = 'Data-quality test outcomes per run. Drives Cortex DQ search + dashboards.';

/* QUARANTINE_RECORD — rows that failed contract/DQ validation, held out of the
   curated layers until resolved. resolution columns give an auditable workflow.
   NOTE: payload would hold sensitive data in production -> mask + restrict. */
CREATE TABLE IF NOT EXISTS QUARANTINE_RECORD (
  quarantine_id     STRING        NOT NULL,
  pipeline_run_id   STRING        COMMENT 'FK -> CONTROL.PIPELINE_RUN.',
  source_table      STRING        COMMENT 'Bronze landing table the row came from.',
  natural_key       STRING        COMMENT 'Business key of the quarantined record.',
  payload           VARIANT       COMMENT 'Offending record payload (SENSITIVE in prod; mask).',
  quarantine_reason STRING        COMMENT 'Why it was quarantined (rule/test).',
  quarantine_status STRING        COMMENT 'OPEN | RESOLVED | DISCARDED | REPROCESSED.',
  created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  resolved_at       TIMESTAMP_NTZ,
  resolved_by       STRING,
  resolution_notes  STRING,
  CONSTRAINT pk_quarantine PRIMARY KEY (quarantine_id)
) COMMENT = 'Quarantined records with resolution workflow. Payload SENSITIVE -> mask in prod.';

/* LINEAGE_EVENT — source->target lineage emitted per transformation node.
   Correlated to dbt via dbt_node_id + dbt_invocation_id. */
CREATE TABLE IF NOT EXISTS LINEAGE_EVENT (
  lineage_event_id    STRING        NOT NULL,
  pipeline_run_id     STRING        COMMENT 'FK -> CONTROL.PIPELINE_RUN.',
  source_object       STRING        COMMENT 'Upstream object.',
  target_object       STRING        COMMENT 'Downstream object produced.',
  transformation_name STRING        COMMENT 'Logical transform/model name.',
  dbt_node_id         STRING        COMMENT 'dbt unique node id.',
  dbt_invocation_id   STRING        COMMENT 'dbt invocation id (artifact correlation).',
  row_count           NUMBER        COMMENT 'Rows produced.',
  created_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_lineage_event PRIMARY KEY (lineage_event_id)
) COMMENT = 'Source->target lineage events per transformation (correlated to dbt artifacts).';

/* MCP_QUERY_LOG — full audit trail of every Cortex Agent / MCP-generated query.
   Critical control: NL question + generated SQL + Snowflake query id + outcome.
   Lets governance review exactly what the LLM surface ran. */
CREATE TABLE IF NOT EXISTS MCP_QUERY_LOG (
  query_log_id       STRING        NOT NULL,
  request_ts         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  client_name        STRING        COMMENT 'MCP client / app name.',
  user_name          STRING        COMMENT 'End user / principal that asked.',
  tool_name          STRING        COMMENT 'analyst | search | sql_exec.',
  question           STRING        COMMENT 'Natural-language question.',
  generated_sql      STRING        COMMENT 'SQL the agent generated/ran.',
  snowflake_query_id STRING        COMMENT 'Snowflake QUERY_ID for cross-ref to ACCOUNT_USAGE.',
  status             STRING        COMMENT 'SUCCESS | ERROR | BLOCKED.',
  row_count          NUMBER        COMMENT 'Rows returned.',
  error_message      STRING,
  execution_ms       NUMBER        COMMENT 'Execution time in ms.',
  CONSTRAINT pk_mcp_query_log PRIMARY KEY (query_log_id)
) COMMENT = 'Audit trail of all Cortex Agent / Snowflake-managed MCP queries (NL + SQL + outcome).';

/* AUDIT grants: transformer/CI write DQ/lineage/quarantine; MCP writes its log;
   analyst reads DQ summary (full quarantine payloads are NOT exposed to MCP). */
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA AUDIT    TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT, INSERT, UPDATE ON FUTURE TABLES IN SCHEMA AUDIT TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA AUDIT    TO ROLE CLAIMS_CI;
GRANT INSERT, SELECT ON TABLE MCP_QUERY_LOG TO ROLE CLAIMS_MCP_READER;

/* =============================================================================
   B) BRONZE LANDING TABLES (BR_RAW_*) — COPY INTO targets.
   -----------------------------------------------------------------------------
   Shared column pattern (provenance + payload + control + audit columns). These
   are append-only, source-faithful, and intentionally untyped beyond the
   provenance columns (the event body stays in `payload VARIANT`). A reusable
   template is applied to all 5 feeds.
   ============================================================================= */
USE SCHEMA BRONZE;

/* --- BR_RAW_CLAIM_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_CLAIM_EVENT (
  bronze_event_id        STRING        COMMENT 'Deterministic row id (file + row number hash).',
  source_system          STRING        COMMENT 'Originating source system.',
  source_file_name       STRING        COMMENT 'Stage file name (METADATA$FILENAME).',
  source_file_row_number NUMBER        COMMENT 'Row number within the file.',
  source_extract_ts      TIMESTAMP_NTZ COMMENT 'Producer-asserted extract timestamp.',
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() COMMENT 'When loaded into bronze.',
  event_type             STRING        COMMENT 'Event type discriminator.',
  business_event_ts      TIMESTAMP_NTZ COMMENT 'Business event time (watermark column).',
  natural_key            STRING        COMMENT 'Business natural key (e.g. claim_id).',
  payload                VARIANT       COMMENT 'Full source-faithful event JSON (SYNTHETIC).',
  payload_hash           STRING        COMMENT 'Hash of payload for dedupe/change detection.',
  record_status          STRING        COMMENT 'LANDED | QUARANTINED | SUPERSEDED.',
  batch_id               STRING        COMMENT 'FK -> CONTROL.LOAD_BATCH.',
  load_id                STRING        COMMENT 'Logical load id.',
  pipeline_run_id        STRING        COMMENT 'FK -> CONTROL.PIPELINE_RUN.',
  is_reprocessed         BOOLEAN       DEFAULT FALSE COMMENT 'TRUE if landed via reprocessing.',
  quarantine_reason      STRING        COMMENT 'Set when record_status=QUARANTINED.',
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw CLAIM events (append-only, source-faithful, SYNTHETIC). COPY INTO target.';

/* --- BR_RAW_ELIGIBILITY_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_ELIGIBILITY_EVENT (
  bronze_event_id        STRING,
  source_system          STRING,
  source_file_name       STRING,
  source_file_row_number NUMBER,
  source_extract_ts      TIMESTAMP_NTZ,
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  event_type             STRING,
  business_event_ts      TIMESTAMP_NTZ,
  natural_key            STRING,
  payload                VARIANT,
  payload_hash           STRING,
  record_status          STRING,
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN DEFAULT FALSE,
  quarantine_reason      STRING,
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw ELIGIBILITY events (append-only, SYNTHETIC). COPY INTO target.';

/* --- BR_RAW_PROVIDER_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_PROVIDER_EVENT (
  bronze_event_id        STRING,
  source_system          STRING,
  source_file_name       STRING,
  source_file_row_number NUMBER,
  source_extract_ts      TIMESTAMP_NTZ,
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  event_type             STRING,
  business_event_ts      TIMESTAMP_NTZ,
  natural_key            STRING,
  payload                VARIANT,
  payload_hash           STRING,
  record_status          STRING,
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN DEFAULT FALSE,
  quarantine_reason      STRING,
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw PROVIDER events (append-only, SYNTHETIC). COPY INTO target.';

/* --- BR_RAW_PHARMACY_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_PHARMACY_EVENT (
  bronze_event_id        STRING,
  source_system          STRING,
  source_file_name       STRING,
  source_file_row_number NUMBER,
  source_extract_ts      TIMESTAMP_NTZ,
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  event_type             STRING,
  business_event_ts      TIMESTAMP_NTZ,
  natural_key            STRING,
  payload                VARIANT,
  payload_hash           STRING,
  record_status          STRING,
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN DEFAULT FALSE,
  quarantine_reason      STRING,
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw PHARMACY events (append-only, SYNTHETIC). COPY INTO target.';

/* --- BR_RAW_ADJUDICATION_EVENT --- */
CREATE TABLE IF NOT EXISTS BR_RAW_ADJUDICATION_EVENT (
  bronze_event_id        STRING,
  source_system          STRING,
  source_file_name       STRING,
  source_file_row_number NUMBER,
  source_extract_ts      TIMESTAMP_NTZ,
  ingest_ts              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  event_type             STRING,
  business_event_ts      TIMESTAMP_NTZ,
  natural_key            STRING,
  payload                VARIANT,
  payload_hash           STRING,
  record_status          STRING,
  batch_id               STRING,
  load_id                STRING,
  pipeline_run_id        STRING,
  is_reprocessed         BOOLEAN DEFAULT FALSE,
  quarantine_reason      STRING,
  created_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Bronze landing: raw ADJUDICATION events (append-only, SYNTHETIC). COPY INTO target.';

/* BRONZE grants: loader writes (COPY INTO); transformer reads for dbt models. */
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA BRONZE    TO ROLE CLAIMS_LOADER;
GRANT INSERT, SELECT ON FUTURE TABLES IN SCHEMA BRONZE TO ROLE CLAIMS_LOADER;
GRANT SELECT ON ALL TABLES IN SCHEMA BRONZE    TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA BRONZE TO ROLE CLAIMS_TRANSFORMER;
-- BRONZE is intentionally NOT granted to CLAIMS_ANALYST or CLAIMS_MCP_READER.

/* DONE. */
