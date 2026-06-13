/* =============================================================================
   003_create_databases_schemas.sql
   snowflake-claims-platform :: Databases & schema topology
   -----------------------------------------------------------------------------
   Creates the platform databases (CLAIMS_DEV default, CLAIMS_PROD) and the
   9-schema medallion+governance topology inside the active database.

   ENVIRONMENT SELECTION (templated)
     This script is parameterised on a session variable `claims_db`. Run it once
     per environment:
         snowsql -f 003_create_databases_schemas.sql           -- defaults to CLAIMS_DEV
         snowsql -D claims_db=CLAIMS_PROD -f 003_create_databases_schemas.sql
     The SET below provides the default; -D / --variable overrides it.

   SCHEMA TOPOLOGY (medallion + governance)
     RAW                : exact-as-landed external feed payloads (stages COPY here).
     BRONZE             : typed landing tables, append-only, source-faithful.
     SILVER_CANONICAL   : conformed/cleaned canonical event entities (dbt).
     SILVER_DIMENSIONAL  : star-schema dims/facts (dbt).
     GOLD               : business marts / certified metrics (dbt).
     CONTROL            : pipeline orchestration metadata (infra, owned here).
     AUDIT              : DQ results, quarantine, lineage, MCP query log (infra).
     SEMANTIC           : semantic view + metric registry/dictionary/runbook.
     CORTEX             : Cortex Search services + Agent objects.

   MANAGED ACCESS SCHEMAS
     We create the governance/curated schemas WITH MANAGED ACCESS so that only
     the schema owner (and security admin) can grant privileges on objects in
     them — object owners cannot hand out their own grants. This centralises
     access control, which matters most for GOLD/SEMANTIC/AUDIT/CONTROL/CORTEX.
     RAW/BRONZE/SILVER_* are left as normal schemas so dbt (object owner) can
     manage intra-pipeline grants ergonomically.

   RUN AS: CLAIMS_SYSADMIN (owns the objects). IDEMPOTENT throughout.
   ============================================================================= */

-- Default environment is DEV; override with -D claims_db=CLAIMS_PROD.
SET claims_db = 'CLAIMS_DEV';

USE ROLE CLAIMS_SYSADMIN;

/* -----------------------------------------------------------------------------
   1. DATABASES
   -----------------------------------------------------------------------------
   We create the targeted environment DB (from $claims_db). For convenience the
   commented block shows creating BOTH; in practice run the script per-env so
   DEV and PROD stay cleanly separated (separate deploy, separate approvals).
   --------------------------------------------------------------------------- */
CREATE DATABASE IF NOT EXISTS IDENTIFIER($claims_db)
  COMMENT = 'snowflake-claims-platform database (SYNTHETIC claims data; no real PHI). Medallion + governance schemas.';

-- Both-environment convenience (uncomment to create the other env explicitly):
-- CREATE DATABASE IF NOT EXISTS CLAIMS_DEV  COMMENT = 'Claims platform - DEV (synthetic).';
-- CREATE DATABASE IF NOT EXISTS CLAIMS_PROD COMMENT = 'Claims platform - PROD (synthetic reference).';

USE DATABASE IDENTIFIER($claims_db);

/* -----------------------------------------------------------------------------
   2. SCHEMAS
   -----------------------------------------------------------------------------
   Medallion data schemas (normal schemas; dbt owns object-level grants).
   --------------------------------------------------------------------------- */
CREATE SCHEMA IF NOT EXISTS RAW
  COMMENT = 'Landing zone: internal stages + COPY INTO targets. Source-exact payloads. SYNTHETIC data.';

CREATE SCHEMA IF NOT EXISTS BRONZE
  COMMENT = 'Typed landing tables (BR_RAW_*). Append-only, source-faithful. Created as infra; dbt processes onward.';

CREATE SCHEMA IF NOT EXISTS SILVER_CANONICAL
  COMMENT = 'Conformed canonical event entities (dbt-owned models).';

CREATE SCHEMA IF NOT EXISTS SILVER_DIMENSIONAL
  COMMENT = 'Star-schema dimensions & facts (dbt-owned models).';

CREATE SCHEMA IF NOT EXISTS GOLD
  WITH MANAGED ACCESS
  COMMENT = 'Certified business marts & metrics (dbt-owned). Managed access: grants centralised.';

/* Governance / platform schemas (managed access; centralised grants). */
CREATE SCHEMA IF NOT EXISTS CONTROL
  WITH MANAGED ACCESS
  COMMENT = 'Pipeline orchestration metadata (config, runs, watermarks, contracts). Infra; owned by setup. Managed access.';

CREATE SCHEMA IF NOT EXISTS AUDIT
  WITH MANAGED ACCESS
  COMMENT = 'DQ results, quarantine, lineage, MCP query log. Infra; owned by setup. Managed access.';

CREATE SCHEMA IF NOT EXISTS SEMANTIC
  WITH MANAGED ACCESS
  COMMENT = 'Semantic view + metric registry / data dictionary / provider lookup / runbook. Managed access.';

CREATE SCHEMA IF NOT EXISTS CORTEX
  WITH MANAGED ACCESS
  COMMENT = 'Cortex Search services + Cortex Agent objects. Managed access.';

/* -----------------------------------------------------------------------------
   3. BASELINE USAGE GRANTS
   -----------------------------------------------------------------------------
   USAGE on DB + relevant schemas so roles can resolve object names. Object-level
   SELECT/INSERT grants and future-grants are applied in the per-object scripts
   (005/006/...) and in 011 for the MCP reader surface.
   --------------------------------------------------------------------------- */
GRANT USAGE ON DATABASE IDENTIFIER($claims_db) TO ROLE CLAIMS_LOADER;
GRANT USAGE ON DATABASE IDENTIFIER($claims_db) TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE ON DATABASE IDENTIFIER($claims_db) TO ROLE CLAIMS_ANALYST;
GRANT USAGE ON DATABASE IDENTIFIER($claims_db) TO ROLE CLAIMS_CI;
GRANT USAGE ON DATABASE IDENTIFIER($claims_db) TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON DATABASE IDENTIFIER($claims_db) TO ROLE CLAIMS_SECURITY_ADMIN;

-- Loader works in RAW + BRONZE only.
GRANT USAGE ON SCHEMA IDENTIFIER($claims_db || '.RAW')    TO ROLE CLAIMS_LOADER;
GRANT USAGE ON SCHEMA IDENTIFIER($claims_db || '.BRONZE') TO ROLE CLAIMS_LOADER;

-- Transformer reads everything upstream, writes curated layers.
GRANT USAGE ON ALL SCHEMAS IN DATABASE IDENTIFIER($claims_db)    TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE IDENTIFIER($claims_db) TO ROLE CLAIMS_TRANSFORMER;

-- Analyst sees only curated GOLD + SEMANTIC.
GRANT USAGE ON SCHEMA IDENTIFIER($claims_db || '.GOLD')     TO ROLE CLAIMS_ANALYST;
GRANT USAGE ON SCHEMA IDENTIFIER($claims_db || '.SEMANTIC') TO ROLE CLAIMS_ANALYST;

-- CI can resolve all schemas to deploy/build.
GRANT USAGE ON ALL SCHEMAS IN DATABASE IDENTIFIER($claims_db)    TO ROLE CLAIMS_CI;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE IDENTIFIER($claims_db) TO ROLE CLAIMS_CI;

-- MCP reader: only GOLD/SEMANTIC/CORTEX (detailed object grants in 011).
GRANT USAGE ON SCHEMA IDENTIFIER($claims_db || '.GOLD')     TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON SCHEMA IDENTIFIER($claims_db || '.SEMANTIC') TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON SCHEMA IDENTIFIER($claims_db || '.CORTEX')   TO ROLE CLAIMS_MCP_READER;

-- Security admin can resolve all schemas to apply policies/tags.
GRANT USAGE ON ALL SCHEMAS IN DATABASE IDENTIFIER($claims_db)    TO ROLE CLAIMS_SECURITY_ADMIN;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE IDENTIFIER($claims_db) TO ROLE CLAIMS_SECURITY_ADMIN;

/* DONE. Schemas exist; per-object grants follow in later scripts. */
