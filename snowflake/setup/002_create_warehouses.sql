/* =============================================================================
   002_create_warehouses.sql
   snowflake-claims-platform :: Compute (virtual warehouses)
   -----------------------------------------------------------------------------
   Creates 5 purpose-built warehouses, one per workload, so compute cost is
   attributable per-function and each workload can be sized/tuned/suspended
   independently. Synthetic-data platform; sizes are intentionally small.

   WHY SEPARATE WAREHOUSES (not one shared)?
     - Cost attribution: each warehouse is a billing boundary.
     - Isolation: a heavy transform run cannot starve interactive analysts.
     - Independent scaling: analysts can multi-cluster; loaders stay XSMALL.
     - Independent governance: different STATEMENT_TIMEOUT / suspend policies.

   COMMON SETTINGS (production patterns)
     AUTO_SUSPEND = 60        : suspend after 60s idle -> you pay only for use.
     AUTO_RESUME  = TRUE      : transparently resume on next query.
     INITIALLY_SUSPENDED=TRUE : create suspended so we are not billed at create.
     STATEMENT_TIMEOUT_*      : guardrail so a runaway query cannot burn credits.

   RUN AS: SYSADMIN (warehouse creation), then grant USAGE to functional roles.
   IDEMPOTENT: CREATE WAREHOUSE IF NOT EXISTS + grants are re-runnable.
   ============================================================================= */

USE ROLE SYSADMIN;

/* -----------------------------------------------------------------------------
   WH_CLAIMS_LOAD  - ingestion (PUT + COPY INTO of NDJSON into BRONZE landing)
   -----------------------------------------------------------------------------
   COPY INTO is I/O bound, not CPU bound. XSMALL is plenty for synthetic feeds.
   Short statement timeout: a load should finish quickly or fail loud.
   --------------------------------------------------------------------------- */
CREATE WAREHOUSE IF NOT EXISTS WH_CLAIMS_LOAD
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Ingestion: PUT to stages + COPY INTO BRONZE landing. I/O bound, XSMALL.';
-- Guardrail: cap a single load statement at 30 min.
ALTER WAREHOUSE WH_CLAIMS_LOAD SET STATEMENT_TIMEOUT_IN_SECONDS = 1800;
ALTER WAREHOUSE WH_CLAIMS_LOAD SET STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 300;

/* -----------------------------------------------------------------------------
   WH_CLAIMS_TRANSFORM - dbt build (BRONZE -> SILVER -> GOLD)
   -----------------------------------------------------------------------------
   Transformations do real work (joins, dedupe, aggregations) so we start at
   SMALL. Bump to MEDIUM+ only if model build times demand it. Longer timeout.
   --------------------------------------------------------------------------- */
CREATE WAREHOUSE IF NOT EXISTS WH_CLAIMS_TRANSFORM
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'dbt transformations BRONZE->SILVER->GOLD. CPU bound, SMALL (scale up if build is slow).';
ALTER WAREHOUSE WH_CLAIMS_TRANSFORM SET STATEMENT_TIMEOUT_IN_SECONDS = 3600;
ALTER WAREHOUSE WH_CLAIMS_TRANSFORM SET STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 600;

/* -----------------------------------------------------------------------------
   WH_CLAIMS_ANALYST - interactive BI / ad-hoc analyst queries
   -----------------------------------------------------------------------------
   XSMALL but a candidate for MULTI-CLUSTER (ECONOMY/STANDARD) under concurrency.
   Multi-cluster is Enterprise+; left commented so the script runs on Standard.
   --------------------------------------------------------------------------- */
CREATE WAREHOUSE IF NOT EXISTS WH_CLAIMS_ANALYST
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Interactive analyst / BI queries over GOLD + SEMANTIC. XSMALL; multi-cluster candidate.';
ALTER WAREHOUSE WH_CLAIMS_ANALYST SET STATEMENT_TIMEOUT_IN_SECONDS = 900;
-- Enterprise+ multi-cluster (uncomment if licensed):
-- ALTER WAREHOUSE WH_CLAIMS_ANALYST SET MIN_CLUSTER_COUNT = 1 MAX_CLUSTER_COUNT = 3 SCALING_POLICY = 'STANDARD';

/* -----------------------------------------------------------------------------
   WH_CLAIMS_CI - CI/CD automation (GitHub Actions: deploy + dbt build + tests)
   -----------------------------------------------------------------------------
   Sized to match transform load it triggers, but isolated so CI noise never
   touches production analyst/transform credit budgets.
   --------------------------------------------------------------------------- */
CREATE WAREHOUSE IF NOT EXISTS WH_CLAIMS_CI
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'CI/CD automation (GitHub Actions): deploy DDL, dbt build/test. Isolated billing boundary.';
ALTER WAREHOUSE WH_CLAIMS_CI SET STATEMENT_TIMEOUT_IN_SECONDS = 3600;

/* -----------------------------------------------------------------------------
   WH_CLAIMS_MCP - Cortex (Analyst/Search/Agent) + Snowflake-managed MCP queries
   -----------------------------------------------------------------------------
   Backs Cortex Search service refresh and Agent/Analyst-generated SQL. Kept
   XSMALL and aggressively suspended; LLM-driven query traffic is bursty.
   --------------------------------------------------------------------------- */
CREATE WAREHOUSE IF NOT EXISTS WH_CLAIMS_MCP
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Cortex Analyst/Search/Agent + Snowflake-managed MCP query execution. Bursty, XSMALL.';
ALTER WAREHOUSE WH_CLAIMS_MCP SET STATEMENT_TIMEOUT_IN_SECONDS = 600;

/* -----------------------------------------------------------------------------
   GRANT USAGE TO THE RIGHT ROLES (least privilege)
   -----------------------------------------------------------------------------
   USAGE = "may run queries on this warehouse". OPERATE = "may suspend/resume".
   We give OPERATE to CI so automation can pre-warm/suspend if needed.
   --------------------------------------------------------------------------- */
GRANT USAGE ON WAREHOUSE WH_CLAIMS_LOAD      TO ROLE CLAIMS_LOADER;
GRANT USAGE ON WAREHOUSE WH_CLAIMS_TRANSFORM TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE ON WAREHOUSE WH_CLAIMS_ANALYST   TO ROLE CLAIMS_ANALYST;
GRANT USAGE ON WAREHOUSE WH_CLAIMS_MCP        TO ROLE CLAIMS_MCP_READER;

-- CI needs to drive all of these during deploy/build.
GRANT USAGE, OPERATE ON WAREHOUSE WH_CLAIMS_CI        TO ROLE CLAIMS_CI;
GRANT USAGE           ON WAREHOUSE WH_CLAIMS_TRANSFORM TO ROLE CLAIMS_CI;
GRANT USAGE           ON WAREHOUSE WH_CLAIMS_LOAD      TO ROLE CLAIMS_CI;

-- Platform admin can operate every warehouse.
GRANT USAGE, OPERATE ON WAREHOUSE WH_CLAIMS_LOAD      TO ROLE CLAIMS_SYSADMIN;
GRANT USAGE, OPERATE ON WAREHOUSE WH_CLAIMS_TRANSFORM TO ROLE CLAIMS_SYSADMIN;
GRANT USAGE, OPERATE ON WAREHOUSE WH_CLAIMS_ANALYST   TO ROLE CLAIMS_SYSADMIN;
GRANT USAGE, OPERATE ON WAREHOUSE WH_CLAIMS_CI        TO ROLE CLAIMS_SYSADMIN;
GRANT USAGE, OPERATE ON WAREHOUSE WH_CLAIMS_MCP        TO ROLE CLAIMS_SYSADMIN;

/* DONE. */
