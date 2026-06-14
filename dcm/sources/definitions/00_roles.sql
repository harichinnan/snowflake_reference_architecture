-- =============================================================================
-- 00_roles.sql  ::  DCM declarative role definitions (account-level)
-- Replaces snowflake/setup/001_create_roles.sql.
-- DEFINE = CREATE OR ALTER; removing a DEFINE drops the role. Order doesn't matter.
-- =============================================================================

DEFINE ROLE CLAIMS_SYSADMIN        COMMENT = 'Platform object owner for the claims platform.';
DEFINE ROLE CLAIMS_LOADER          COMMENT = 'Stage + COPY INTO RAW/BRONZE only.';
DEFINE ROLE CLAIMS_TRANSFORMER     COMMENT = 'dbt builds BRONZE->SILVER->GOLD + CONTROL/AUDIT.';
DEFINE ROLE CLAIMS_ANALYST         COMMENT = 'Read-only on GOLD/SEMANTIC for BI/Workbooks.';
DEFINE ROLE CLAIMS_CI              COMMENT = 'CI builds in isolated schemas (ceiling for automation).';
DEFINE ROLE CLAIMS_MCP_READER      COMMENT = 'Read-only access layer for the MCP server.';
DEFINE ROLE CLAIMS_SECURITY_ADMIN  COMMENT = 'Applies policies, masking, tags, grants (SoD).';

-- ---- Role hierarchy (functional -> CLAIMS_SYSADMIN -> SYSADMIN) --------------
GRANT ROLE CLAIMS_LOADER       TO ROLE CLAIMS_SYSADMIN;
GRANT ROLE CLAIMS_TRANSFORMER  TO ROLE CLAIMS_SYSADMIN;
GRANT ROLE CLAIMS_ANALYST      TO ROLE CLAIMS_SYSADMIN;
GRANT ROLE CLAIMS_CI           TO ROLE CLAIMS_SYSADMIN;
GRANT ROLE CLAIMS_MCP_READER   TO ROLE CLAIMS_SYSADMIN;
GRANT ROLE CLAIMS_SYSADMIN       TO ROLE SYSADMIN;
GRANT ROLE CLAIMS_SECURITY_ADMIN TO ROLE SECURITYADMIN;

-- NOTE: With DCM the project owner creates the database directly, so the old
-- imperative "GRANT CREATE DATABASE ON ACCOUNT TO CLAIMS_SYSADMIN" is no longer
-- needed -- DCM owns the lifecycle of {{ database }} (see 02_databases_schemas.sql).
