/* =============================================================================
   012_create_semantic_views.sql
   snowflake-claims-platform :: SEMANTIC schema (semantic view + doc tables)
   -----------------------------------------------------------------------------
   GOAL
     1. Create the supporting SEMANTIC doc/reference tables (populated by
        semantic/*.sql seeds, NOT here): METRIC_REGISTRY, DATA_DICTIONARY,
        PROVIDER_LOOKUP, CLAIMS_RUNBOOK. (These back Cortex Search in 009.)
     2. Create CLAIMS_SEMANTIC_VIEW — a Snowflake SEMANTIC VIEW (logical tables,
        dimensions, metrics) over the dbt GOLD/SILVER_DIMENSIONAL star. This is
        the grounding model for Cortex Analyst (used by the agent in 010 and the
        managed MCP in 011). If CREATE SEMANTIC VIEW is unavailable in the
        account, a governed analytic VIEW fallback is created instead.
     3. Create the approved read-only MCP views (MCP_FACT_CLAIM_LINE, MCP_GOLD_*)
        — the explicit, narrow objects the MCP surface is allowed to read.

   DEPENDENCY NOTE
     The SEMANTIC VIEW and MCP_* views reference dbt-owned GOLD/SILVER_DIMENSIONAL
     models (FCT_CLAIM_LINE, FCT_ADJUDICATION, DIM_PROVIDER, DIM_MEMBER, DIM_DATE,
     AGG_MEMBER_MONTHS). Run after an initial `dbt build`. The doc TABLES have no
     such dependency and can be created anytime.

   Synthetic data — definitions/dimensions describe synthetic claims; no real PHI.

   RUN AS: CLAIMS_SYSADMIN. Parameterised on $claims_db. IDEMPOTENT.
   ============================================================================= */

SET claims_db = 'CLAIMS_DEV';   -- override: -D claims_db=CLAIMS_PROD

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);
USE SCHEMA SEMANTIC;

/* =============================================================================
   1. DOC / REFERENCE TABLES (created here; ROWS seeded by semantic/*.sql)
   ============================================================================= */

-- Presentation-facing metric registry (mirrors CONTROL.SEMANTIC_METRIC_REGISTRY
-- but is the object Cortex Search/Analyst read). Populated by seeds.
CREATE TABLE IF NOT EXISTS METRIC_REGISTRY (
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
) COMMENT = 'Certified metric definitions (presentation). Backs Cortex metric-doc search. Seeded by semantic/*.sql.';

-- Column-level data dictionary; backs Cortex metric-doc search.
CREATE TABLE IF NOT EXISTS DATA_DICTIONARY (
  object_name STRING NOT NULL COMMENT 'Schema-qualified object.',
  column_name STRING NOT NULL,
  data_type   STRING,
  description STRING,
  is_pii      BOOLEAN DEFAULT FALSE COMMENT 'Marks columns that would be PII in a real system.',
  created_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_data_dictionary PRIMARY KEY (object_name, column_name)
) COMMENT = 'Column-level documentation for governed objects. Backs Cortex search. Seeded by semantic/*.sql.';

-- Provider directory; backs CLAIMS_PROVIDER_SEARCH (009).
CREATE TABLE IF NOT EXISTS PROVIDER_LOOKUP (
  provider_id    STRING NOT NULL,
  provider_name  STRING,
  specialty      STRING,
  city           STRING,
  state          STRING,
  network_status STRING COMMENT 'IN_NETWORK | OUT_OF_NETWORK.',
  created_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_provider_lookup PRIMARY KEY (provider_id)
) COMMENT = 'Synthetic provider directory. Backs CLAIMS_PROVIDER_SEARCH. Seeded by semantic/*.sql.';

-- Operational runbook; backs CLAIMS_DATA_QUALITY_SEARCH (009).
CREATE TABLE IF NOT EXISTS CLAIMS_RUNBOOK (
  runbook_id STRING NOT NULL,
  title      STRING,
  category   STRING COMMENT 'INGESTION | DQ | REPROCESSING | FRESHNESS | SECURITY.',
  content    STRING COMMENT 'Runbook body / remediation steps.',
  created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_claims_runbook PRIMARY KEY (runbook_id)
) COMMENT = 'Operational runbook entries. Backs CLAIMS_DATA_QUALITY_SEARCH. Seeded by semantic/*.sql.';

/* =============================================================================
   2. SEMANTIC VIEW — Cortex Analyst grounding over the gold/dimensional star.
   -----------------------------------------------------------------------------
   A Snowflake SEMANTIC VIEW declares LOGICAL TABLES (mapped to physical
   gold/dimensional objects), their RELATIONSHIPS, DIMENSIONS (slicing attrs),
   and METRICS (governed aggregations). Cortex Analyst uses it to translate NL to
   correct, certified SQL. We wrap the DDL so a non-supporting account falls back
   to a governed analytic VIEW carrying the same join + the core measures.
   ============================================================================= */
EXECUTE IMMEDIATE $$
BEGIN
  CREATE OR REPLACE SEMANTIC VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW
    TABLES (
      claim_line AS CLAIMS_DEV.GOLD.FCT_CLAIM_LINE
        PRIMARY KEY (claim_line_id)
        COMMENT = 'Claim line fact (SYNTHETIC).',
      provider AS CLAIMS_DEV.SILVER_DIMENSIONAL.DIM_PROVIDER
        PRIMARY KEY (provider_key)
        COMMENT = 'Provider dimension.',
      member AS CLAIMS_DEV.SILVER_DIMENSIONAL.DIM_MEMBER
        PRIMARY KEY (member_key)
        COMMENT = 'Member dimension.',
      dates AS CLAIMS_DEV.SILVER_DIMENSIONAL.DIM_DATE
        PRIMARY KEY (date_key)
        COMMENT = 'Date dimension.'
    )
    RELATIONSHIPS (
      claim_to_provider AS claim_line (provider_key) REFERENCES provider (provider_key),
      claim_to_member   AS claim_line (member_key)   REFERENCES member (member_key),
      claim_to_date     AS claim_line (service_date_key) REFERENCES dates (date_key)
    )
    DIMENSIONS (
      provider.specialty       AS specialty       COMMENT 'Provider specialty.',
      provider.network_status  AS network_status  COMMENT 'In/out of network.',
      member.plan_type         AS plan_type       COMMENT 'Member plan type.',
      dates.calendar_month     AS service_month    COMMENT 'Service month.'
    )
    METRICS (
      claim_line.total_paid    AS SUM(claim_line.paid_amount)    COMMENT 'Total paid $.',
      claim_line.total_allowed AS SUM(claim_line.allowed_amount) COMMENT 'Total allowed $.',
      claim_line.total_billed  AS SUM(claim_line.billed_amount)  COMMENT 'Total billed $.',
      claim_line.claim_count   AS COUNT(DISTINCT claim_line.claim_id) COMMENT 'Distinct claims.'
    )
    COMMENT = 'Cortex Analyst semantic model over the claims star (SYNTHETIC). Certified grounding for NL->SQL.';
  SYSTEM$LOG('info', 'CLAIMS_SEMANTIC_VIEW (SEMANTIC VIEW) created.');
EXCEPTION
  WHEN OTHER THEN
    -- Fallback: governed analytic view carrying the same join + measures, so
    -- downstream references (Analyst/MCP) still resolve. Built only if the
    -- underlying dbt models exist.
    BEGIN
      CREATE OR REPLACE VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW
        COMMENT = 'Fallback governed analytic view (SEMANTIC VIEW DDL unavailable). SYNTHETIC.'
      AS
        SELECT
          f.claim_id, f.claim_line_id, f.service_date,
          p.specialty, p.network_status,
          m.plan_type,
          f.paid_amount, f.allowed_amount, f.billed_amount
        FROM CLAIMS_DEV.GOLD.FCT_CLAIM_LINE f
        LEFT JOIN CLAIMS_DEV.SILVER_DIMENSIONAL.DIM_PROVIDER p ON p.provider_key = f.provider_key
        LEFT JOIN CLAIMS_DEV.SILVER_DIMENSIONAL.DIM_MEMBER   m ON m.member_key   = f.member_key;
      SYSTEM$LOG('warn', 'SEMANTIC VIEW unavailable; created fallback analytic view CLAIMS_SEMANTIC_VIEW.');
    EXCEPTION
      WHEN OTHER THEN
        SYSTEM$LOG('warn', 'Neither SEMANTIC VIEW nor fallback could be built yet (dbt models missing?). Re-run after dbt build.');
    END;
END;
$$;

/* =============================================================================
   3. APPROVED READ-ONLY MCP VIEWS (the narrow surface MCP may read).
   -----------------------------------------------------------------------------
   Explicit, curated, column-projected views (no SELECT *). These are the only
   row-level objects the MCP/agent SQL tool should touch. Wrapped so missing dbt
   models do not abort the script.
   ============================================================================= */
EXECUTE IMMEDIATE $$
BEGIN
  -- Claim-line fact, MCP-safe projection (explicit columns, no internal keys).
  CREATE OR REPLACE VIEW SEMANTIC.MCP_FACT_CLAIM_LINE
    COMMENT = 'MCP-approved claim-line fact projection. SELECT-only surface. SYNTHETIC.'
  AS
    SELECT claim_id, claim_line_id, service_date,
           primary_diagnosis_code, billed_amount, allowed_amount, paid_amount
    FROM CLAIMS_DEV.GOLD.FCT_CLAIM_LINE;

  -- Gold monthly paid rollup, MCP-safe.
  CREATE OR REPLACE VIEW SEMANTIC.MCP_GOLD_PAID_MONTHLY
    COMMENT = 'MCP-approved monthly paid rollup. SYNTHETIC.'
  AS
    SELECT DATE_TRUNC('month', service_date) AS service_month,
           SUM(paid_amount) AS total_paid, SUM(allowed_amount) AS total_allowed
    FROM CLAIMS_DEV.GOLD.FCT_CLAIM_LINE
    GROUP BY 1;

  -- Gold provider rollup, MCP-safe.
  CREATE OR REPLACE VIEW SEMANTIC.MCP_GOLD_PROVIDER_PAID
    COMMENT = 'MCP-approved paid-by-provider rollup. SYNTHETIC.'
  AS
    SELECT pr.provider_id, pr.provider_name, pr.specialty,
           SUM(f.paid_amount) AS total_paid, COUNT(*) AS claim_lines
    FROM CLAIMS_DEV.GOLD.FCT_CLAIM_LINE f
    JOIN CLAIMS_DEV.SILVER_DIMENSIONAL.DIM_PROVIDER pr ON pr.provider_key = f.provider_key
    GROUP BY 1,2,3;

  SYSTEM$LOG('info', 'MCP_* approved views created.');
EXCEPTION
  WHEN OTHER THEN
    SYSTEM$LOG('warn', 'MCP_* views not built (dbt GOLD/dim models missing?). Re-run after dbt build.');
END;
$$;

/* =============================================================================
   4. GRANTS
   ============================================================================= */
-- Doc tables: analyst reads; MCP reads (handled broadly in 011, restated safely).
GRANT SELECT ON ALL TABLES IN SCHEMA SEMANTIC    TO ROLE CLAIMS_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA SEMANTIC TO ROLE CLAIMS_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA SEMANTIC    TO ROLE CLAIMS_ANALYST;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA SEMANTIC  TO ROLE CLAIMS_ANALYST;

-- Transformer/CI may seed the doc tables.
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA SEMANTIC    TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT, INSERT, UPDATE ON FUTURE TABLES IN SCHEMA SEMANTIC TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA SEMANTIC    TO ROLE CLAIMS_CI;

-- Semantic view usage for Cortex Analyst grounding (wrapped for object-type portability).
EXECUTE IMMEDIATE $$
BEGIN
  GRANT SELECT ON SEMANTIC VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW TO ROLE CLAIMS_MCP_READER;
  GRANT SELECT ON SEMANTIC VIEW SEMANTIC.CLAIMS_SEMANTIC_VIEW TO ROLE CLAIMS_ANALYST;
EXCEPTION
  WHEN OTHER THEN
    -- Fallback object is a plain VIEW; ALL VIEWS grant above already covers it.
    SYSTEM$LOG('info', 'CLAIMS_SEMANTIC_VIEW is a plain view; covered by ALL VIEWS grant.');
END;
$$;

/* DONE.
   This completes scripts 001..012. Run order via snowsql:
     for f in 001 002 003 004 005 006 007 008 009 010 011 012; do
       snowsql -f snowflake/setup/${f}_*.sql ;   # add -D claims_db=CLAIMS_PROD for prod
     done
   (008/009/010/012 reference dbt-built GOLD/dim models; run after an initial
    `dbt build`, or expect the wrapped/commented sections to no-op until models
    exist.) */
