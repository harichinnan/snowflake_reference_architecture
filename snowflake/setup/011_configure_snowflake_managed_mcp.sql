/* =============================================================================
   011_configure_snowflake_managed_mcp.sql
   snowflake-claims-platform :: Snowflake-managed MCP server exposure
   -----------------------------------------------------------------------------
   PRIMARY MCP = SNOWFLAKE-MANAGED MCP.
     This platform exposes its Cortex Analyst + Cortex Search + Cortex Agent
     capabilities through the SNOWFLAKE-MANAGED MCP server (an account-native MCP
     endpoint hosted by Snowflake, secured by Snowflake auth + RBAC). The older
     "Snowflake-Labs" open-source MCP server is DEPRECATED for this platform and
     is NOT used.

   WHAT MCP CAN AND CANNOT ACCESS (the whole point of this script)
     CAN (read-only, SELECT only):
       - GOLD presentation views/marts.
       - SEMANTIC views + the semantic view (Cortex Analyst grounding).
       - Selected SILVER_DIMENSIONAL dimension/fact views (curated).
       - Selected AUDIT SUMMARY views (DQ rollups; NO raw payloads).
       - The 3 Cortex Search services + the Cortex Agent.
     CANNOT (explicitly denied):
       - RAW and BRONZE (source-faithful / pre-curation data).
       - CONTROL internals (config/watermarks/run ledger).
       - Full AUDIT.QUARANTINE_RECORD payloads (sensitive offending records).
       - Any write: no INSERT/UPDATE/DELETE/MERGE/DDL. SELECT-only role.

   The access boundary is enforced by GRANTS to CLAIMS_MCP_READER (the role the
   managed MCP server authenticates as). MCP can only see what this role can see.

   Synthetic data — even so, we treat the surface as if it were real PHI.

   RUN AS: CLAIMS_SYSADMIN for object grants; SECURITYADMIN-class for the service
   user. Parameterised on $claims_db. IDEMPOTENT.
   ============================================================================= */

SET claims_db = 'CLAIMS_DEV';   -- override: -D claims_db=CLAIMS_PROD

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);

/* =============================================================================
   1. AUDIT SUMMARY VIEWS — safe rollups MCP may read (NO raw payloads).
   -----------------------------------------------------------------------------
   We never expose AUDIT.QUARANTINE_RECORD.payload to MCP. Instead we expose
   aggregate/summary views that omit payloads entirely.
   ============================================================================= */
USE SCHEMA AUDIT;

CREATE VIEW IF NOT EXISTS VW_DQ_SUMMARY
  COMMENT = 'MCP-safe DQ rollup. No row-level payloads. SYNTHETIC.'
AS
  SELECT DATE_TRUNC('day', created_at) AS check_day, model_name, severity, status,
         COUNT(*) AS test_count, SUM(failed_row_count) AS failed_rows
  FROM AUDIT.DATA_QUALITY_RESULT
  GROUP BY 1,2,3,4;

CREATE VIEW IF NOT EXISTS VW_QUARANTINE_SUMMARY
  COMMENT = 'MCP-safe quarantine rollup. Reason/status counts only; NO payloads. SYNTHETIC.'
AS
  SELECT source_table, quarantine_reason, quarantine_status,
         COUNT(*) AS record_count, MIN(created_at) AS first_seen, MAX(created_at) AS last_seen
  FROM AUDIT.QUARANTINE_RECORD
  GROUP BY 1,2,3;

/* =============================================================================
   2. CLAIMS_MCP_READER GRANTS — the exact read-only surface.
   -----------------------------------------------------------------------------
   The role (created in 001) already has DB/schema USAGE on GOLD/SEMANTIC/CORTEX
   (from 003) and dynamic-table/search grants (007/009/010). Here we finalise the
   curated read surface and the audit-summary exposure.
   ============================================================================= */

-- GOLD: all presentation views + marts (SELECT-only).
GRANT SELECT ON ALL VIEWS  IN SCHEMA GOLD TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA GOLD TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA GOLD TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA GOLD TO ROLE CLAIMS_MCP_READER;

-- SEMANTIC: views + the semantic view + doc tables (registry/dictionary/lookup).
GRANT SELECT ON ALL VIEWS  IN SCHEMA SEMANTIC TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA SEMANTIC TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA SEMANTIC TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA SEMANTIC TO ROLE CLAIMS_MCP_READER;

-- SILVER_DIMENSIONAL: SELECTED curated dim/fact VIEWS only (not whole schema).
-- Grant per-object so we exclude any non-curated/internal models. Examples:
GRANT USAGE ON SCHEMA SILVER_DIMENSIONAL TO ROLE CLAIMS_MCP_READER;
EXECUTE IMMEDIATE $$
BEGIN
  GRANT SELECT ON VIEW SILVER_DIMENSIONAL.DIM_PROVIDER TO ROLE CLAIMS_MCP_READER;
  GRANT SELECT ON VIEW SILVER_DIMENSIONAL.DIM_MEMBER   TO ROLE CLAIMS_MCP_READER;
  GRANT SELECT ON VIEW SILVER_DIMENSIONAL.DIM_DATE     TO ROLE CLAIMS_MCP_READER;
EXCEPTION
  WHEN OTHER THEN
    SYSTEM$LOG('info', 'Some SILVER_DIMENSIONAL dim views not yet built by dbt; grant later.');
END;
$$;

-- AUDIT: only the SAFE SUMMARY views (never base tables / payloads).
GRANT USAGE  ON SCHEMA AUDIT                       TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON VIEW AUDIT.VW_DQ_SUMMARY           TO ROLE CLAIMS_MCP_READER;
GRANT SELECT ON VIEW AUDIT.VW_QUARANTINE_SUMMARY   TO ROLE CLAIMS_MCP_READER;
-- (Deliberately NO grant on AUDIT.DATA_QUALITY_RESULT / QUARANTINE_RECORD base.)

-- Compute for MCP-driven queries (granted in 002; restated for clarity).
GRANT USAGE ON WAREHOUSE WH_CLAIMS_MCP TO ROLE CLAIMS_MCP_READER;

/* =============================================================================
   3. OPTIONAL SERVICE USER for the managed MCP (key-pair auth).
   -----------------------------------------------------------------------------
   The Snowflake-managed MCP authenticates as a principal bound to
   CLAIMS_MCP_READER. Use a dedicated service user with RSA key-pair auth (never
   a password). Created with SECURITYADMIN. RSA_PUBLIC_KEY is a placeholder.
   ============================================================================= */
USE ROLE SECURITYADMIN;

CREATE USER IF NOT EXISTS CLAIMS_MCP_SERVICE_USER
  DEFAULT_ROLE = CLAIMS_MCP_READER
  DEFAULT_WAREHOUSE = WH_CLAIMS_MCP
  DEFAULT_NAMESPACE = 'CLAIMS_DEV.SEMANTIC'
  MUST_CHANGE_PASSWORD = FALSE
  COMMENT = 'Service user for Snowflake-managed MCP. Key-pair auth. SELECT-only via CLAIMS_MCP_READER.';

-- Set the real public key (base64 DER, no PEM headers) when provisioning:
-- ALTER USER CLAIMS_MCP_SERVICE_USER SET RSA_PUBLIC_KEY = '<BASE64_DER_PUBLIC_KEY>';

GRANT ROLE CLAIMS_MCP_READER TO USER CLAIMS_MCP_SERVICE_USER;

/* =============================================================================
   4. MANAGED MCP SERVER ENDPOINT BINDING (Cortex Analyst + Search + Agent)
   -----------------------------------------------------------------------------
   The Snowflake-managed MCP server is an account-native endpoint. It is enabled
   /configured at the account level (Snowsight: AI & ML / MCP, or via the
   account's MCP configuration), and exposes the tools below to MCP clients
   (e.g. Claude, IDEs) that authenticate as CLAIMS_MCP_SERVICE_USER.

   The binding wires these objects as MCP tools:
       - Cortex Agent      : CORTEX.CLAIMS_AGENT                (orchestrator)
       - Cortex Analyst    : SEMANTIC.CLAIMS_SEMANTIC_VIEW      (text-to-SQL)
       - Cortex Search x3  : CORTEX.CLAIMS_PROVIDER_SEARCH,
                             CORTEX.CLAIMS_METRIC_DOC_SEARCH,
                             CORTEX.CLAIMS_DATA_QUALITY_SEARCH

   If your account supports the managed-MCP object DDL, the wrapped block creates
   it; otherwise enable + bind these tools via Snowsight using the same object
   references. Either way, the access ceiling is CLAIMS_MCP_READER (SELECT-only).
   ============================================================================= */
USE ROLE CLAIMS_SYSADMIN;
USE SCHEMA CORTEX;

EXECUTE IMMEDIATE $$
BEGIN
  -- Managed-MCP server object DDL (availability varies by account/region).
  CREATE OR REPLACE MCP SERVER CLAIMS_MANAGED_MCP
    COMMENT = 'Snowflake-managed MCP for the claims platform. SELECT-only via CLAIMS_MCP_READER. SYNTHETIC data.'
    FROM SPECIFICATION $SPEC$
    tools:
      - name: claims_agent
        type: CORTEX_AGENT
        identifier: CLAIMS_DEV.CORTEX.CLAIMS_AGENT
      - name: claims_analyst
        type: CORTEX_ANALYST
        identifier: CLAIMS_DEV.SEMANTIC.CLAIMS_SEMANTIC_VIEW
      - name: provider_search
        type: CORTEX_SEARCH
        identifier: CLAIMS_DEV.CORTEX.CLAIMS_PROVIDER_SEARCH
      - name: metric_doc_search
        type: CORTEX_SEARCH
        identifier: CLAIMS_DEV.CORTEX.CLAIMS_METRIC_DOC_SEARCH
      - name: data_quality_search
        type: CORTEX_SEARCH
        identifier: CLAIMS_DEV.CORTEX.CLAIMS_DATA_QUALITY_SEARCH
    $SPEC$;
  GRANT USAGE ON MCP SERVER CLAIMS_MANAGED_MCP TO ROLE CLAIMS_MCP_READER;
  SYSTEM$LOG('info', 'CLAIMS_MANAGED_MCP server created and granted to CLAIMS_MCP_READER.');
EXCEPTION
  WHEN OTHER THEN
    -- Managed-MCP DDL not available in this account: enable + bind the same
    -- tools via Snowsight (AI & ML > MCP). The CLAIMS_MCP_READER grants above
    -- already enforce the SELECT-only access ceiling for the endpoint.
    SYSTEM$LOG('warn', 'MCP SERVER DDL not available; configure managed MCP via Snowsight binding the tools listed in this file.');
END;
$$;

/* DONE.
   SUMMARY OF THE ACCESS CONTRACT:
     MCP authenticates as CLAIMS_MCP_SERVICE_USER -> CLAIMS_MCP_READER ->
     SELECT-only on GOLD + SEMANTIC + selected SILVER_DIMENSIONAL dims + AUDIT
     summary views + the Cortex Search/Agent tools. No RAW/BRONZE/CONTROL, no
     quarantine payloads, no writes of any kind. */
