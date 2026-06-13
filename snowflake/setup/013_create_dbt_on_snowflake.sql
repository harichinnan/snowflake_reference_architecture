-- =============================================================================
-- 013_create_dbt_on_snowflake.sql
-- -----------------------------------------------------------------------------
-- "dbt Projects on Snowflake" — run dbt NATIVELY inside Snowflake (server-side)
-- instead of (or in addition to) local dbt Core. This is the most Snowflake-
-- native orchestration path: the dbt project becomes a schema-level DBT PROJECT
-- object, executed with EXECUTE DBT PROJECT and schedulable with a TASK. No
-- external runner, no cloud — 100% Snowflake.
--
-- GA reference:
--   https://docs.snowflake.com/en/user-guide/data-engineering/dbt-projects-on-snowflake
--   CREATE DBT PROJECT / EXECUTE DBT PROJECT (SQL), and `snow dbt deploy` (CLI).
--
-- Run order: AFTER 001-006 (roles, warehouses, db/schemas, control/audit tables).
-- Some statements require ACCOUNTADMIN (external access integration / network
-- rule); the project object + grants use functional roles. Role context is
-- marked per-section below.
--
-- Data is SYNTHETIC — not real CMS/Medicare/Medicaid/PHI.
-- =============================================================================

-- Templated database (default CLAIMS_DEV; override: -D claims_db=CLAIMS_PROD).
SET claims_db = 'CLAIMS_DEV';

-- =============================================================================
-- 1) EGRESS for server-side `dbt deps`  (ACCOUNTADMIN)
-- -----------------------------------------------------------------------------
-- When dbt runs inside Snowflake, `dbt deps` fetches packages (dbt_utils,
-- dbt_expectations) from the dbt package hub / GitHub. That outbound network
-- call must be allowed via a NETWORK RULE + EXTERNAL ACCESS INTEGRATION.
--
-- ALTERNATIVE (no egress): pre-fetch packages locally (`dbt deps`) and deploy
-- them with `snow dbt deploy --install-local-deps`. Then you can SKIP this
-- section and omit EXTERNAL_ACCESS_INTEGRATIONS from the project object.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE IDENTIFIER($claims_db);

-- A small, dedicated schema to hold integration-support objects + the project.
CREATE SCHEMA IF NOT EXISTS DBT
  COMMENT = 'dbt Projects on Snowflake: DBT PROJECT objects + egress support.';

CREATE OR REPLACE NETWORK RULE DBT.DBT_PACKAGE_HUB_EGRESS
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = (
    'hub.getdbt.com',
    'codeload.github.com',
    'github.com',
    'objects.githubusercontent.com',
    'raw.githubusercontent.com'
  )
  COMMENT = 'Allow dbt deps to download packages from the dbt hub / GitHub.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION CLAIMS_DBT_EAI
  ALLOWED_NETWORK_RULES = (DBT.DBT_PACKAGE_HUB_EGRESS)
  ENABLED = TRUE
  COMMENT = 'External access for dbt deps in dbt Projects on Snowflake.';

-- Let the transformer role use the integration when executing the project.
GRANT USAGE ON INTEGRATION CLAIMS_DBT_EAI TO ROLE CLAIMS_TRANSFORMER;

-- =============================================================================
-- 2) Privileges to own + run the DBT PROJECT object  (ACCOUNTADMIN/SECURITYADMIN)
-- =============================================================================
GRANT USAGE ON SCHEMA IDENTIFIER($claims_db) || '.DBT' TO ROLE CLAIMS_TRANSFORMER;
-- (If the IDENTIFIER concat form is rejected by your client, run the explicit
--  grant instead, e.g.:  GRANT USAGE ON SCHEMA CLAIMS_DEV.DBT TO ROLE CLAIMS_TRANSFORMER;)
USE SCHEMA DBT;
GRANT CREATE DBT PROJECT ON SCHEMA DBT TO ROLE CLAIMS_TRANSFORMER;

-- EXECUTE DBT PROJECT runs as the role in the project's profiles.yml outputs
-- (CLAIMS_TRANSFORMER) and is further limited to the caller's privileges. That
-- role already has build privileges on BRONZE/SILVER_*/GOLD/CONTROL/AUDIT.

-- =============================================================================
-- 3) Create the DBT PROJECT object  (CLAIMS_TRANSFORMER)
-- -----------------------------------------------------------------------------
-- RECOMMENDED: create/update it from the CLI, which uploads your local files:
--
--   snow dbt deploy CLAIMS_DBT_PROJECT \
--     --source dbt \
--     --profiles-dir dbt/snowflake_profiles \
--     --default-target dev \
--     --external-access-integration CLAIMS_DBT_EAI \
--     --connection my_example_connection
--
-- The block below is the equivalent SQL form when your project files already
-- live in a stage or a Snowsight Workspace / Git repository stage. The source
-- directory must contain dbt_project.yml at its root (and profiles.yml).
--
-- DBT_VERSION is pinned to a Snowflake-SUPPORTED dbt Core version (1.10.15).
-- Snowflake does NOT run dbt 1.11 server-side; local dev may differ. See
-- docs/dbt_on_snowflake.md.
-- =============================================================================
USE ROLE CLAIMS_TRANSFORMER;
USE DATABASE IDENTIFIER($claims_db);
USE SCHEMA DBT;

/*  -- Example: deploy from a Git repository stage (see section 6 for the git repo).
CREATE OR REPLACE DBT PROJECT CLAIMS_DBT_PROJECT
  FROM '@DBT.CLAIMS_DBT_REPO/branches/main/dbt'
  DBT_VERSION = '1.10.15'
  DEFAULT_TARGET = 'dev'
  EXTERNAL_ACCESS_INTEGRATIONS = (CLAIMS_DBT_EAI)
  COMMENT = 'Synthetic claims platform — bronze->silver->gold + DCM controls.';
*/

-- =============================================================================
-- 4) Execute the project  (CLAIMS_TRANSFORMER)
-- -----------------------------------------------------------------------------
-- ARGS is a normal dbt CLI string. Run deps once (needs the EAI), then build.
-- =============================================================================
/*
EXECUTE DBT PROJECT CLAIMS_DBT_PROJECT ARGS = 'deps';
EXECUTE DBT PROJECT CLAIMS_DBT_PROJECT ARGS = 'seed --target dev';
EXECUTE DBT PROJECT CLAIMS_DBT_PROJECT ARGS = 'build --target dev';
EXECUTE DBT PROJECT CLAIMS_DBT_PROJECT ARGS = 'test  --target dev';
-- Run a slice:
-- EXECUTE DBT PROJECT CLAIMS_DBT_PROJECT ARGS = 'build --select silver_canonical+ --target dev';
*/

-- =============================================================================
-- 5) Schedule it natively with a TASK  (replaces an external scheduler)
-- -----------------------------------------------------------------------------
-- Snowflake Tasks are the native orchestrator. This runs the full build on a
-- schedule against prod. Created SUSPENDED — resume when ready.
-- =============================================================================
CREATE OR REPLACE TASK DBT.CLAIMS_DBT_BUILD_DAILY
  WAREHOUSE = WH_CLAIMS_TRANSFORM
  SCHEDULE = 'USING CRON 0 6 * * * America/New_York'
  COMMENT = 'Daily native dbt build of the synthetic claims platform (prod).'
AS
  EXECUTE DBT PROJECT CLAIMS_DBT_PROJECT ARGS = 'build --target prod';

-- Grant the ability to run tasks, then leave the task SUSPENDED for safety.
-- (EXECUTE TASK is an account-level privilege; granted by ACCOUNTADMIN.)
-- USE ROLE ACCOUNTADMIN; GRANT EXECUTE TASK ON ACCOUNT TO ROLE CLAIMS_TRANSFORMER;
ALTER TASK DBT.CLAIMS_DBT_BUILD_DAILY SUSPEND;
-- To activate:  ALTER TASK DBT.CLAIMS_DBT_BUILD_DAILY RESUME;
-- One-off run:  EXECUTE TASK DBT.CLAIMS_DBT_BUILD_DAILY;

-- =============================================================================
-- 6) OPTIONAL — Git-native deploy (no CLI upload)  (ACCOUNTADMIN)
-- -----------------------------------------------------------------------------
-- Bind the GitHub repo directly so Snowflake reads the dbt project from git and
-- you redeploy by ALTERing the project to a new branch/commit. Public repo =>
-- no secret needed. Uncomment to use.
-- =============================================================================
/*
USE ROLE ACCOUNTADMIN;
USE DATABASE IDENTIFIER($claims_db);
USE SCHEMA DBT;

CREATE OR REPLACE API INTEGRATION CLAIMS_GIT_API
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/harichinnan/')
  ENABLED = TRUE
  COMMENT = 'Read public GitHub for git-native dbt project deploys.';

CREATE OR REPLACE GIT REPOSITORY DBT.CLAIMS_DBT_REPO
  API_INTEGRATION = CLAIMS_GIT_API
  ORIGIN = 'https://github.com/harichinnan/snowflake_reference_architecture.git'
  COMMENT = 'Snowflake-claims-platform source for dbt Projects on Snowflake.';

ALTER GIT REPOSITORY DBT.CLAIMS_DBT_REPO FETCH;
GRANT READ ON GIT REPOSITORY DBT.CLAIMS_DBT_REPO TO ROLE CLAIMS_TRANSFORMER;
-- Then use the FROM '@DBT.CLAIMS_DBT_REPO/branches/main/dbt' form in section 3.
*/

-- =============================================================================
-- Verify
-- =============================================================================
-- SHOW DBT PROJECTS IN SCHEMA DBT;
-- SHOW TASKS IN SCHEMA DBT;
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY()) ORDER BY scheduled_time DESC;
