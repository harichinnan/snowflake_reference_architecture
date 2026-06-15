/* =============================================================================
   006_create_audit_tables.sql
   snowflake-claims-platform :: AUDIT schema observability tables
   -----------------------------------------------------------------------------
   AUDIT schema observability tables (owned by setup, not dbt):
        DATA_QUALITY_RESULT  : per-test DQ outcomes (from dbt tests / checks).
        QUARANTINE_RECORD    : rows that failed validation, held for resolution.
        LINEAGE_EVENT        : source->target transformation lineage events.
        MCP_QUERY_LOG        : every Cortex/MCP-generated query (auditability).

   NOTE: the BR_RAW_* landing tables that used to be created here have MOVED to
   snowflake/setup/016_create_raw_landing.sql, into the new RAW_LANDING schema
   (the physical ingestion landing / COPY INTO targets). BRONZE.BR_RAW_* are now
   created EXCLUSIVELY by the dbt bronze models -- setup no longer creates them.

   Synthetic data only — payloads contain NO real PHI. The QUARANTINE_RECORD
   payload VARIANT column would, in a real system, hold sensitive data and MUST
   be masked + access-restricted (handled by CLAIMS_SECURITY_ADMIN).

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
   B) BRONZE LANDING TABLES (BR_RAW_*) — MOVED.
   -----------------------------------------------------------------------------
   The physical landing tables (BR_RAW_CLAIM_EVENT, BR_RAW_ELIGIBILITY_EVENT,
   BR_RAW_PROVIDER_EVENT, BR_RAW_PHARMACY_EVENT, BR_RAW_ADJUDICATION_EVENT) used
   to be created HERE in the BRONZE schema. They now live in the RAW_LANDING
   schema -- see snowflake/setup/016_create_raw_landing.sql. dbt owns
   BRONZE.BR_RAW_* (model outputs); ingestion lands in RAW_LANDING.BR_RAW_*.
   ============================================================================= */

/* DONE. */
