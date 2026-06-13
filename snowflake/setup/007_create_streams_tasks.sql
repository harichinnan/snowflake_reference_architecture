/* =============================================================================
   007_create_streams_tasks.sql
   snowflake-claims-platform :: Snowflake-native orchestration
   -----------------------------------------------------------------------------
   Demonstrates the three Snowflake-native orchestration primitives and WHEN to
   use each vs dbt-via-GitHub-Actions. Everything that runs compute is created
   SUSPENDED so this script never silently starts billing.

   DECISION GUIDE — Streams vs Tasks vs Dynamic Tables vs dbt/CI
   -----------------------------------------------------------------------------
   STREAM (CDC):
     A change-tracking cursor over a table. Tells you WHAT changed since you last
     consumed it. Zero compute by itself. Use to drive incremental processing
     and to detect "is there new data to act on?".

   TASK (scheduled/triggered SQL):
     Runs SQL (or calls a stored proc) on a CRON schedule or when triggered, and
     can be conditioned on `SYSTEM$STREAM_HAS_DATA(...)` so it only burns compute
     when a stream actually has changes. Use for: in-Snowflake MERGE loops,
     calling dbt-built procedures, freshness checks, alert population. Tasks form
     DAGs via AFTER dependencies.

   DYNAMIC TABLE (declarative, auto-refreshed):
     You declare the target SELECT + a TARGET_LAG; Snowflake keeps it fresh
     incrementally. No streams/tasks to wire. Use for derived tables whose logic
     is a pure SELECT and where "keep it within N minutes fresh" is the contract.
     Great for serving/current-state views feeding dashboards.

   dbt via GitHub Actions (the PRIMARY transformation path here):
     The medallion BRONZE->SILVER->GOLD model graph, tests, docs, and lineage are
     OWNED BY dbt and deployed through CI (WH_CLAIMS_CI / WH_CLAIMS_TRANSFORM).
     Use dbt for: versioned, tested, peer-reviewed business logic. Use the native
     primitives below for the thin operational glue dbt does not cover (CDC
     signals, micro-batch serving tables, in-warehouse housekeeping/alerts).

   RULE OF THUMB: business transformations -> dbt. Operational glue / CDC /
   low-latency serving -> Streams/Tasks/Dynamic Tables.

   RUN AS: CLAIMS_SYSADMIN. Parameterised on $claims_db. IDEMPOTENT.
   ============================================================================= */

SET claims_db = 'CLAIMS_DEV';   -- override: -D claims_db=CLAIMS_PROD

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);

/* =============================================================================
   1. STREAMS — one per bronze landing table (CDC over new arrivals).
   -----------------------------------------------------------------------------
   APPEND_ONLY = TRUE because bronze is append-only; this is the cheapest stream
   type and exactly matches the access pattern. A downstream task consumes the
   stream to drive incremental processing without rescanning the whole table.
   ============================================================================= */
USE SCHEMA BRONZE;

CREATE STREAM IF NOT EXISTS STR_BR_CLAIM_EVENT
  ON TABLE BR_RAW_CLAIM_EVENT        APPEND_ONLY = TRUE
  COMMENT = 'CDC over new CLAIM landings. Drives incremental downstream processing.';

CREATE STREAM IF NOT EXISTS STR_BR_ELIGIBILITY_EVENT
  ON TABLE BR_RAW_ELIGIBILITY_EVENT  APPEND_ONLY = TRUE
  COMMENT = 'CDC over new ELIGIBILITY landings.';

CREATE STREAM IF NOT EXISTS STR_BR_PROVIDER_EVENT
  ON TABLE BR_RAW_PROVIDER_EVENT     APPEND_ONLY = TRUE
  COMMENT = 'CDC over new PROVIDER landings.';

CREATE STREAM IF NOT EXISTS STR_BR_PHARMACY_EVENT
  ON TABLE BR_RAW_PHARMACY_EVENT     APPEND_ONLY = TRUE
  COMMENT = 'CDC over new PHARMACY landings.';

CREATE STREAM IF NOT EXISTS STR_BR_ADJUDICATION_EVENT
  ON TABLE BR_RAW_ADJUDICATION_EVENT APPEND_ONLY = TRUE
  COMMENT = 'CDC over new ADJUDICATION landings.';

/* =============================================================================
   2. TASKS — created SUSPENDED. Two illustrative patterns.
   -----------------------------------------------------------------------------
   Tasks are created in CONTROL (operational glue lives with control metadata).
   They are SUSPENDED on creation; an operator/CI RESUMEs them deliberately.
   ============================================================================= */
USE SCHEMA CONTROL;

/* (a) Stream-gated trigger task: when new CLAIM data exists, do work.
       Here it simply stamps a heartbeat run row; in production the body would
       CALL a dbt-built stored procedure or run a MERGE. WHEN guards compute so
       the task is free to schedule frequently. */
CREATE TASK IF NOT EXISTS TSK_PROCESS_CLAIM_BRONZE
  WAREHOUSE = WH_CLAIMS_TRANSFORM
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('BRONZE.STR_BR_CLAIM_EVENT')
  COMMENT = 'Stream-gated: process newly landed CLAIM events. Replace body with dbt-proc CALL or MERGE.'
AS
  INSERT INTO CONTROL.PIPELINE_RUN
    (pipeline_run_id, pipeline_name, environment, run_status, started_at, completed_at)
  SELECT UUID_STRING(), 'claim_event', $claims_db, 'SUCCESS', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP();

/* (b) Scheduled freshness-check task (no stream gate): recompute SLA status.
       Populates CONTROL.PIPELINE_FRESHNESS_STATUS from observed bronze ingest
       times vs configured max_allowed_lag_hours. Runs hourly. */
CREATE TASK IF NOT EXISTS TSK_REFRESH_FRESHNESS_STATUS
  WAREHOUSE = WH_CLAIMS_TRANSFORM
  SCHEDULE = 'USING CRON 0 * * * * UTC'
  COMMENT = 'Hourly freshness/lag SLA evaluation -> CONTROL.PIPELINE_FRESHNESS_STATUS.'
AS
  MERGE INTO CONTROL.PIPELINE_FRESHNESS_STATUS t
  USING (
    SELECT
      c.pipeline_name,
      c.source_system,
      f.latest_source_extract_ts,
      f.latest_ingest_ts,
      c.max_allowed_lag_hours,
      CASE
        WHEN f.latest_ingest_ts IS NULL THEN 'STALE'
        WHEN DATEDIFF('hour', f.latest_source_extract_ts, CURRENT_TIMESTAMP()) <= c.max_allowed_lag_hours THEN 'FRESH'
        WHEN DATEDIFF('hour', f.latest_source_extract_ts, CURRENT_TIMESTAMP()) <= c.max_allowed_lag_hours * 2 THEN 'STALE'
        ELSE 'BREACHED'
      END AS freshness_status
    FROM CONTROL.PIPELINE_CONFIG c
    LEFT JOIN (
      SELECT 'claim_event' AS pipeline_name,
             MAX(source_extract_ts) AS latest_source_extract_ts,
             MAX(ingest_ts)         AS latest_ingest_ts
      FROM BRONZE.BR_RAW_CLAIM_EVENT
      -- UNION ALL the other feeds here in a real deployment.
    ) f ON f.pipeline_name = c.pipeline_name
    WHERE c.is_active
  ) s
  ON t.pipeline_name = s.pipeline_name
  WHEN MATCHED THEN UPDATE SET
    source_system = s.source_system,
    latest_source_extract_ts = s.latest_source_extract_ts,
    latest_ingest_ts = s.latest_ingest_ts,
    max_allowed_lag_hours = s.max_allowed_lag_hours,
    freshness_status = s.freshness_status,
    alert_severity = CASE s.freshness_status WHEN 'BREACHED' THEN 'CRITICAL' WHEN 'STALE' THEN 'WARN' ELSE 'NONE' END,
    checked_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT
    (pipeline_name, source_system, latest_source_extract_ts, latest_ingest_ts,
     max_allowed_lag_hours, freshness_status, alert_severity, checked_at)
    VALUES (s.pipeline_name, s.source_system, s.latest_source_extract_ts, s.latest_ingest_ts,
            s.max_allowed_lag_hours, s.freshness_status,
            CASE s.freshness_status WHEN 'BREACHED' THEN 'CRITICAL' WHEN 'STALE' THEN 'WARN' ELSE 'NONE' END,
            CURRENT_TIMESTAMP());

-- Tasks are SUSPENDED at creation by default. Be explicit so intent is clear.
-- RESUME deliberately (operator/CI) once dbt models + bodies are finalised:
--   ALTER TASK CONTROL.TSK_PROCESS_CLAIM_BRONZE RESUME;
--   ALTER TASK CONTROL.TSK_REFRESH_FRESHNESS_STATUS RESUME;
ALTER TASK IF EXISTS TSK_PROCESS_CLAIM_BRONZE      SUSPEND;
ALTER TASK IF EXISTS TSK_REFRESH_FRESHNESS_STATUS  SUSPEND;

/* =============================================================================
   3. DYNAMIC TABLE — declarative auto-refreshed "current claims" serving table.
   -----------------------------------------------------------------------------
   Demonstrates the pattern: pick the latest event per claim (by business_event_ts)
   directly off bronze, kept fresh within TARGET_LAG with no streams/tasks to
   manage. In production this would sit over a dbt SILVER model, not raw bronze;
   shown over bronze here so the script is self-contained.

   TARGET_LAG '1 hour' = Snowflake guarantees data no older than ~1h. REFRESH_MODE
   AUTO lets Snowflake choose incremental vs full. Lives in GOLD (serving layer).
   ============================================================================= */
USE SCHEMA GOLD;

CREATE DYNAMIC TABLE IF NOT EXISTS DT_CURRENT_CLAIM
  TARGET_LAG = '1 hour'
  WAREHOUSE = WH_CLAIMS_TRANSFORM
  REFRESH_MODE = AUTO
  INITIALIZE = ON_CREATE
  COMMENT = 'Auto-refreshed current-state per claim (latest event). DEMO over bronze; prod sits over a dbt SILVER model. SYNTHETIC.'
AS
  SELECT
    natural_key                AS claim_id,
    source_system,
    event_type,
    business_event_ts,
    payload,
    ingest_ts
  FROM (
    SELECT
      b.*,
      ROW_NUMBER() OVER (
        PARTITION BY b.natural_key
        ORDER BY b.business_event_ts DESC, b.ingest_ts DESC
      ) AS rn
    FROM CLAIMS_DEV.BRONZE.BR_RAW_CLAIM_EVENT b
    WHERE b.record_status = 'LANDED'
  )
  WHERE rn = 1;

/* GRANTS: transformer owns/operates; analyst & MCP may read the serving table. */
GRANT SELECT ON DYNAMIC TABLE GOLD.DT_CURRENT_CLAIM TO ROLE CLAIMS_ANALYST;
GRANT SELECT ON DYNAMIC TABLE GOLD.DT_CURRENT_CLAIM TO ROLE CLAIMS_MCP_READER;
GRANT OPERATE ON TASK CONTROL.TSK_PROCESS_CLAIM_BRONZE     TO ROLE CLAIMS_CI;
GRANT OPERATE ON TASK CONTROL.TSK_REFRESH_FRESHNESS_STATUS TO ROLE CLAIMS_CI;

/* DONE. Streams created; tasks SUSPENDED; one demo dynamic table live. */
