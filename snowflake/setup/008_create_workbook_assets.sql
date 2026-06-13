/* =============================================================================
   008_create_workbook_assets.sql
   snowflake-claims-platform :: Workbook / Notebook supporting views
   -----------------------------------------------------------------------------
   SNOWFLAKE WORKBOOKS / NOTEBOOKS — capability note
     Snowsight provides two native interactive surfaces:
       * Worksheets / "Workbooks": tabbed SQL workspaces, shareable, with charts
         and dashboard tiles built from query results.
       * Snowflake Notebooks: cell-based (SQL + Python via Snowpark) documents
         that run on a warehouse or container runtime, good for narrative
         analysis, visualisation, and lightweight ML.
     Both EXECUTE QUERIES against database objects; they do not store the
     business logic durably. Best practice (applied here): put the logic in
     governed VIEWS, and let workbook/notebook CELLS be thin SELECTs over those
     views. That keeps logic version-controlled, testable, and reusable, while
     the notebook stays a presentation layer. Notebooks themselves are managed
     in Snowsight / via Git integration, not created by this DDL.

   WHAT THIS CREATES
     Ten thin presentation VIEWS in GOLD that workbook cells query. Each is a
     thin SELECT over a dbt-owned GOLD model. The GOLD models are produced by
     dbt; these views DEPEND ON them. We use CREATE VIEW IF NOT EXISTS so the
     script is idempotent, but note: a view referencing a not-yet-built dbt model
     will fail to compile. Run this AFTER an initial `dbt build`, OR keep the
     CREATE statements commented until the models exist (commented variants are
     provided). Synthetic data throughout.

   RUN AS: CLAIMS_SYSADMIN. Parameterised on $claims_db. IDEMPOTENT.
   ============================================================================= */

SET claims_db = 'CLAIMS_DEV';   -- override: -D claims_db=CLAIMS_PROD

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);
USE SCHEMA GOLD;

/* -----------------------------------------------------------------------------
   PRESENTATION VIEWS (thin SELECTs over dbt GOLD models)
   -----------------------------------------------------------------------------
   The referenced GOLD.FCT_* / DIM_* / AGG_* objects are dbt-owned. Adjust the
   model names to match the dbt project. Each view is deliberately simple so the
   workbook cell is a one-liner: SELECT * FROM GOLD.VW_X.
   --------------------------------------------------------------------------- */

-- Claim volume over time.
CREATE VIEW IF NOT EXISTS VW_CLAIMS_VOLUME
  COMMENT = 'Workbook: claim counts by service month. Depends on dbt GOLD.FCT_CLAIM_LINE. SYNTHETIC.'
AS
  SELECT DATE_TRUNC('month', service_date) AS service_month,
         COUNT(*)                          AS claim_line_count,
         COUNT(DISTINCT claim_id)          AS claim_count
  FROM GOLD.FCT_CLAIM_LINE
  GROUP BY 1;

-- Paid amount trend.
CREATE VIEW IF NOT EXISTS VW_PAID_TREND
  COMMENT = 'Workbook: paid $ trend by month. Depends on GOLD.FCT_CLAIM_LINE. SYNTHETIC.'
AS
  SELECT DATE_TRUNC('month', service_date) AS service_month,
         SUM(paid_amount)                  AS total_paid,
         SUM(allowed_amount)               AS total_allowed,
         SUM(billed_amount)                AS total_billed
  FROM GOLD.FCT_CLAIM_LINE
  GROUP BY 1;

-- PMPM (per-member-per-month) cost.
CREATE VIEW IF NOT EXISTS VW_PMPM
  COMMENT = 'Workbook: PMPM = paid / member-months. Depends on GOLD.FCT_CLAIM_LINE + GOLD.AGG_MEMBER_MONTHS. SYNTHETIC.'
AS
  SELECT p.service_month,
         p.total_paid,
         m.member_months,
         DIV0(p.total_paid, m.member_months) AS pmpm
  FROM (SELECT DATE_TRUNC('month', service_date) AS service_month, SUM(paid_amount) AS total_paid
        FROM GOLD.FCT_CLAIM_LINE GROUP BY 1) p
  JOIN GOLD.AGG_MEMBER_MONTHS m ON m.service_month = p.service_month;

-- Provider utilisation.
CREATE VIEW IF NOT EXISTS VW_PROVIDER_UTIL
  COMMENT = 'Workbook: utilisation + paid by provider. Depends on GOLD.FCT_CLAIM_LINE + DIM_PROVIDER. SYNTHETIC.'
AS
  SELECT pr.provider_id, pr.provider_name, pr.specialty,
         COUNT(*) AS claim_lines, SUM(f.paid_amount) AS total_paid
  FROM GOLD.FCT_CLAIM_LINE f
  JOIN GOLD.DIM_PROVIDER pr ON pr.provider_key = f.provider_key
  GROUP BY 1,2,3;

-- Cost by condition / diagnosis.
CREATE VIEW IF NOT EXISTS VW_CONDITION_COST
  COMMENT = 'Workbook: paid $ by primary diagnosis / condition. Depends on GOLD.FCT_CLAIM_LINE. SYNTHETIC.'
AS
  SELECT primary_diagnosis_code AS condition_code,
         COUNT(DISTINCT claim_id) AS claims, SUM(paid_amount) AS total_paid
  FROM GOLD.FCT_CLAIM_LINE
  GROUP BY 1;

-- Late-arrival impact (how much paid $ arrived after the SLA window).
CREATE VIEW IF NOT EXISTS VW_LATE_ARRIVAL_IMPACT
  COMMENT = 'Workbook: paid $ from late-arriving claims by month. Depends on GOLD.FCT_CLAIM_LINE. SYNTHETIC.'
AS
  SELECT DATE_TRUNC('month', service_date) AS service_month,
         SUM(CASE WHEN DATEDIFF('day', service_date, ingest_date) > 30 THEN paid_amount ELSE 0 END) AS late_paid,
         SUM(paid_amount) AS total_paid
  FROM GOLD.FCT_CLAIM_LINE
  GROUP BY 1;

-- Data-quality dashboard (reads AUDIT directly; infra, always available).
CREATE VIEW IF NOT EXISTS VW_DQ_DASHBOARD
  COMMENT = 'Workbook: DQ pass/fail rollup. Reads AUDIT.DATA_QUALITY_RESULT (infra). SYNTHETIC.'
AS
  SELECT DATE_TRUNC('day', created_at) AS check_day, model_name, severity, status,
         COUNT(*) AS test_count, SUM(failed_row_count) AS failed_rows
  FROM AUDIT.DATA_QUALITY_RESULT
  GROUP BY 1,2,3,4;

-- Adjustment analysis.
CREATE VIEW IF NOT EXISTS VW_ADJUSTMENT_ANALYSIS
  COMMENT = 'Workbook: adjustment $ and counts by reason. Depends on GOLD.FCT_ADJUDICATION. SYNTHETIC.'
AS
  SELECT adjustment_reason_code,
         COUNT(*) AS adjustment_count,
         SUM(adjustment_amount) AS total_adjustment
  FROM GOLD.FCT_ADJUDICATION
  GROUP BY 1;

-- Member months.
CREATE VIEW IF NOT EXISTS VW_MEMBER_MONTHS
  COMMENT = 'Workbook: member-months by month. Depends on GOLD.AGG_MEMBER_MONTHS. SYNTHETIC.'
AS
  SELECT service_month, member_months
  FROM GOLD.AGG_MEMBER_MONTHS;

-- Denial analysis.
CREATE VIEW IF NOT EXISTS VW_DENIAL_ANALYSIS
  COMMENT = 'Workbook: denial rate + denied $ by reason. Depends on GOLD.FCT_ADJUDICATION. SYNTHETIC.'
AS
  SELECT denial_reason_code,
         COUNT(*) AS denied_lines,
         SUM(billed_amount) AS denied_billed,
         DIV0(COUNT(*), (SELECT COUNT(*) FROM GOLD.FCT_ADJUDICATION)) AS denial_rate
  FROM GOLD.FCT_ADJUDICATION
  WHERE status = 'DENIED'
  GROUP BY 1;

/* GRANTS: analysts and MCP reader can SELECT the presentation views. */
GRANT SELECT ON ALL VIEWS IN SCHEMA GOLD    TO ROLE CLAIMS_ANALYST;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA GOLD TO ROLE CLAIMS_ANALYST;

/* =============================================================================
   STARTER WORKBOOK CELLS (paste into a Snowsight Workbook / Notebook)
   -----------------------------------------------------------------------------
   -- Cell 1: context
   --   USE ROLE CLAIMS_ANALYST; USE WAREHOUSE WH_CLAIMS_ANALYST;
   --   USE DATABASE CLAIMS_DEV; USE SCHEMA GOLD;
   -- Cell 2: paid trend (line chart on service_month / total_paid)
   --   SELECT * FROM VW_PAID_TREND ORDER BY service_month;
   -- Cell 3: PMPM (line chart)
   --   SELECT * FROM VW_PMPM ORDER BY service_month;
   -- Cell 4: top providers (bar)
   --   SELECT * FROM VW_PROVIDER_UTIL ORDER BY total_paid DESC LIMIT 20;
   -- Cell 5: denial analysis (bar)
   --   SELECT * FROM VW_DENIAL_ANALYSIS ORDER BY denied_billed DESC;
   -- Cell 6: DQ health (table, color by status)
   --   SELECT * FROM VW_DQ_DASHBOARD ORDER BY check_day DESC;
   ============================================================================= */

/* DONE. */
