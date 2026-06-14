/* =============================================================================
   04_audit_tables.sql
   DCM declarative definitions for the AUDIT schema.
   -----------------------------------------------------------------------------
   Replaces the AUDIT-schema CREATE TABLEs in
   snowflake/setup/006_create_audit_tables.sql (group A). The BRONZE landing
   tables from that same script are defined separately in 05_bronze_landing.sql.

   DCM-declarative DEFINE TABLE statements (CREATE-OR-ALTER form). No CREATE /
   IF NOT EXISTS / OR REPLACE; every object is fully qualified with the
   {{ database }} Jinja variable (CLAIMS_DEV / CLAIMS_PROD). No DML.
   ============================================================================= */

DEFINE TABLE {{ database }}.AUDIT.DATA_QUALITY_RESULT (
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
)
COMMENT = 'Data-quality test outcomes per run. Drives Cortex DQ search + dashboards.';

DEFINE TABLE {{ database }}.AUDIT.QUARANTINE_RECORD (
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
)
COMMENT = 'Quarantined records with resolution workflow. Payload SENSITIVE -> mask in prod.';

DEFINE TABLE {{ database }}.AUDIT.LINEAGE_EVENT (
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
)
COMMENT = 'Source->target lineage events per transformation (correlated to dbt artifacts).';

DEFINE TABLE {{ database }}.AUDIT.MCP_QUERY_LOG (
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
)
COMMENT = 'Audit trail of all Cortex Agent / Snowflake-managed MCP queries (NL + SQL + outcome).';
