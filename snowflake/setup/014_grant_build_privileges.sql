-- =============================================================================
-- 014_grant_build_privileges.sql
-- -----------------------------------------------------------------------------
-- Grant CLAIMS_TRANSFORMER the privileges dbt needs to BUILD models (local dbt
-- Core or dbt Projects on Snowflake). Scripts 003/005/012 granted USAGE +
-- table DML on CONTROL/SEMANTIC, but dbt also needs CREATE TABLE/VIEW on the
-- model schemas and SELECT on its sources (BRONZE landing, seeds), plus INSERT
-- into AUDIT (quarantine + DQ results from macros/tests).
--
-- Run as ACCOUNTADMIN (after 003-006). Least-privilege: only the build role,
-- only the schemas it writes; the analyst/MCP read roles are scoped in 011/012.
--
-- Data is SYNTHETIC — not real CMS/Medicare/Medicaid/PHI.
-- =============================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE CLAIMS_DEV;

-- dbt issues `create schema if not exists` for custom schemas; allow it (our
-- generate_schema_name override targets existing schemas, but grant for safety).
GRANT CREATE SCHEMA ON DATABASE CLAIMS_DEV TO ROLE CLAIMS_TRANSFORMER;

-- ---- Schemas dbt materializes into: CREATE TABLE/VIEW + read own outputs ----
-- RAW holds dbt seeds; BRONZE/SILVER_*/GOLD/CONTROL/SEMANTIC hold models.
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA RAW                TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA BRONZE             TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA SILVER_CANONICAL   TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA SILVER_DIMENSIONAL TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA GOLD               TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA CONTROL            TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA SEMANTIC           TO ROLE CLAIMS_TRANSFORMER;

-- ---- SELECT on sources dbt reads but does not own --------------------------
-- BRONZE landing tables (created by setup 006), and anything pre-seeded.
GRANT SELECT ON ALL TABLES    IN SCHEMA BRONZE  TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA BRONZE  TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT ON ALL TABLES    IN SCHEMA RAW     TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW     TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT ON ALL VIEWS     IN SCHEMA BRONZE  TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA BRONZE  TO ROLE CLAIMS_TRANSFORMER;

-- ---- AUDIT: macros/tests write quarantine + DQ results ----------------------
GRANT SELECT, INSERT, UPDATE ON ALL TABLES    IN SCHEMA AUDIT TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT, INSERT, UPDATE ON FUTURE TABLES IN SCHEMA AUDIT TO ROLE CLAIMS_TRANSFORMER;

-- ---- CONTROL: read config + write watermarks/run state ----------------------
-- (003/005 granted SELECT/INSERT/UPDATE on CONTROL tables; CREATE TABLE above
--  lets the dbt control/* models materialize there.)
GRANT SELECT ON ALL TABLES    IN SCHEMA CONTROL TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CONTROL TO ROLE CLAIMS_TRANSFORMER;

-- Warehouse to run the builds (already granted in 002, repeated idempotently).
GRANT USAGE ON WAREHOUSE WH_CLAIMS_TRANSFORM TO ROLE CLAIMS_TRANSFORMER;
