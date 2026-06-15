-- =============================================================================
-- 08_grants.sql  ::  DCM least-privilege grants
-- Consolidates the grant statements previously scattered across setup
-- 002/003/004/005/012/014. (Role-to-role hierarchy grants live in 00_roles.sql.)
--
-- NOTE: object grants on tables that DCM also DEFINEs are managed declaratively.
-- "FUTURE <object>" grants are included so dbt-created models inherit access; if
-- your account/region does not yet manage FUTURE grants via DCM, keep just those
-- few lines in an imperative companion (see dcm/README.md).
-- =============================================================================

-- ---- Warehouse usage --------------------------------------------------------
GRANT USAGE ON WAREHOUSE WH_CLAIMS_LOAD      TO ROLE CLAIMS_LOADER;
GRANT USAGE ON WAREHOUSE WH_CLAIMS_TRANSFORM TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE ON WAREHOUSE WH_CLAIMS_ANALYST   TO ROLE CLAIMS_ANALYST;
GRANT USAGE ON WAREHOUSE WH_CLAIMS_CI        TO ROLE CLAIMS_CI;
GRANT USAGE ON WAREHOUSE WH_CLAIMS_MCP       TO ROLE CLAIMS_MCP_READER;

-- ---- Database usage ---------------------------------------------------------
GRANT USAGE ON DATABASE {{ database }} TO ROLE CLAIMS_LOADER;
GRANT USAGE ON DATABASE {{ database }} TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE ON DATABASE {{ database }} TO ROLE CLAIMS_ANALYST;
GRANT USAGE ON DATABASE {{ database }} TO ROLE CLAIMS_CI;
GRANT USAGE ON DATABASE {{ database }} TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON DATABASE {{ database }} TO ROLE CLAIMS_SECURITY_ADMIN;

-- ---- LOADER: write RAW + RAW_LANDING (physical landing) ---------------------
-- RAW_LANDING is the COPY INTO / loader target (BR_RAW_*). BRONZE.BR_RAW_* are
-- dbt outputs; the loader does NOT write BRONZE anymore.
GRANT USAGE ON SCHEMA {{ database }}.RAW         TO ROLE CLAIMS_LOADER;
GRANT USAGE ON SCHEMA {{ database }}.RAW_LANDING TO ROLE CLAIMS_LOADER;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES    IN SCHEMA {{ database }}.RAW_LANDING TO ROLE CLAIMS_LOADER;
GRANT SELECT, INSERT, UPDATE ON FUTURE TABLES IN SCHEMA {{ database }}.RAW_LANDING TO ROLE CLAIMS_LOADER;

-- ---- TRANSFORMER: build the medallion + control plane ----------------------
GRANT USAGE                  ON SCHEMA {{ database }}.RAW                TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE                  ON SCHEMA {{ database }}.RAW_LANDING        TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE                  ON SCHEMA {{ database }}.BRONZE             TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE                  ON SCHEMA {{ database }}.SILVER_CANONICAL   TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE                  ON SCHEMA {{ database }}.SILVER_DIMENSIONAL TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE                  ON SCHEMA {{ database }}.GOLD               TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE                  ON SCHEMA {{ database }}.CONTROL            TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE                  ON SCHEMA {{ database }}.AUDIT              TO ROLE CLAIMS_TRANSFORMER;
GRANT USAGE                  ON SCHEMA {{ database }}.SEMANTIC           TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA {{ database }}.RAW                TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA {{ database }}.BRONZE             TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA {{ database }}.SILVER_CANONICAL   TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA {{ database }}.SILVER_DIMENSIONAL TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA {{ database }}.GOLD               TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA {{ database }}.CONTROL            TO ROLE CLAIMS_TRANSFORMER;
GRANT CREATE TABLE, CREATE VIEW ON SCHEMA {{ database }}.SEMANTIC           TO ROLE CLAIMS_TRANSFORMER;
-- read its sources, write control/audit
GRANT SELECT          ON ALL TABLES    IN SCHEMA {{ database }}.RAW_LANDING TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT          ON FUTURE TABLES IN SCHEMA {{ database }}.RAW_LANDING TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT          ON FUTURE TABLES IN SCHEMA {{ database }}.BRONZE  TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT          ON FUTURE TABLES IN SCHEMA {{ database }}.RAW     TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT, INSERT, UPDATE ON FUTURE TABLES IN SCHEMA {{ database }}.CONTROL TO ROLE CLAIMS_TRANSFORMER;
GRANT SELECT, INSERT, UPDATE ON FUTURE TABLES IN SCHEMA {{ database }}.AUDIT   TO ROLE CLAIMS_TRANSFORMER;

-- ---- ANALYST: read curated GOLD + SEMANTIC ---------------------------------
GRANT USAGE ON SCHEMA {{ database }}.GOLD     TO ROLE CLAIMS_ANALYST;
GRANT USAGE ON SCHEMA {{ database }}.SEMANTIC TO ROLE CLAIMS_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA {{ database }}.GOLD     TO ROLE CLAIMS_ANALYST;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA {{ database }}.GOLD     TO ROLE CLAIMS_ANALYST;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA {{ database }}.SEMANTIC TO ROLE CLAIMS_ANALYST;

-- ---- MCP_READER: read-only GOLD/SEMANTIC/CORTEX only (NO RAW/BRONZE) --------
GRANT USAGE ON SCHEMA {{ database }}.GOLD     TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON SCHEMA {{ database }}.SEMANTIC TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON SCHEMA {{ database }}.CORTEX   TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA {{ database }}.GOLD     TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA {{ database }}.SEMANTIC TO ROLE CLAIMS_MCP_READER;

-- ---- CI: build everything in isolated schemas ------------------------------
GRANT USAGE ON SCHEMA {{ database }}.RAW                TO ROLE CLAIMS_CI;
GRANT USAGE ON SCHEMA {{ database }}.RAW_LANDING        TO ROLE CLAIMS_CI;
GRANT USAGE ON SCHEMA {{ database }}.BRONZE             TO ROLE CLAIMS_CI;
GRANT USAGE ON SCHEMA {{ database }}.SILVER_CANONICAL   TO ROLE CLAIMS_CI;
GRANT USAGE ON SCHEMA {{ database }}.SILVER_DIMENSIONAL TO ROLE CLAIMS_CI;
GRANT USAGE ON SCHEMA {{ database }}.GOLD               TO ROLE CLAIMS_CI;
