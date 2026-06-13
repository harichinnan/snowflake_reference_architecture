/* =============================================================================
   009_create_cortex_search.sql
   snowflake-claims-platform :: Cortex Search services
   -----------------------------------------------------------------------------
   PREREQUISITES
     - Account must have Snowflake Cortex enabled (and Cortex Search available in
       the region). If not enabled, these CREATEs fail; contact ACCOUNTADMIN to
       enable Cortex features. (CORTEX_SEARCH and related are governed by the
       SNOWFLAKE.CORTEX privileges / account features.)
     - The source objects (SEMANTIC.PROVIDER_LOOKUP, SEMANTIC.METRIC_REGISTRY,
       SEMANTIC.DATA_DICTIONARY, SEMANTIC.CLAIMS_RUNBOOK) are created in script
       012; AUDIT.DATA_QUALITY_RESULT + QUARANTINE_RECORD in 006. Run those first.

   WHAT THIS CREATES (in CORTEX schema)
     CLAIMS_PROVIDER_SEARCH     : semantic search over the provider directory.
     CLAIMS_METRIC_DOC_SEARCH   : search over metric definitions + data dictionary.
     CLAIMS_DATA_QUALITY_SEARCH : search over DQ failures + quarantine summaries
                                  + the operational runbook.

   Each service indexes a SEARCH (text) column, exposes ATTRIBUTES for filtering,
   runs refresh on WH_CLAIMS_MCP, and has a TARGET_LAG governing index freshness.
   These services are consumed by the Cortex Agent (010) and the managed MCP (011).

   Synthetic data — indexed text describes synthetic providers/metrics/DQ.

   RUN AS: CLAIMS_SYSADMIN. Parameterised on $claims_db. IDEMPOTENT
   (CREATE OR REPLACE; rebuilding an index is safe, just recomputes).
   ============================================================================= */

SET claims_db = 'CLAIMS_DEV';   -- override: -D claims_db=CLAIMS_PROD

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);
USE SCHEMA CORTEX;

/* -----------------------------------------------------------------------------
   1. CLAIMS_PROVIDER_SEARCH  — over SEMANTIC.PROVIDER_LOOKUP
   -----------------------------------------------------------------------------
   Lets the agent resolve fuzzy provider mentions ("the cardiology group in
   Austin") to provider_id values. ON column = the free-text description we
   embed/index; ATTRIBUTES = structured fields we can filter on.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE CORTEX SEARCH SERVICE CLAIMS_PROVIDER_SEARCH
  ON search_text
  ATTRIBUTES provider_id, provider_name, specialty, state, network_status
  WAREHOUSE = WH_CLAIMS_MCP
  TARGET_LAG = '1 hour'
  COMMENT = 'Semantic search over the synthetic provider directory (resolve provider mentions -> provider_id).'
AS
  SELECT
    provider_id,
    provider_name,
    specialty,
    state,
    network_status,
    -- Concatenate searchable fields into one indexed text column.
    provider_name || ' | ' || COALESCE(specialty,'') || ' | ' ||
      COALESCE(city,'') || ', ' || COALESCE(state,'') || ' | ' ||
      COALESCE(network_status,'') AS search_text
  FROM SEMANTIC.PROVIDER_LOOKUP;

/* -----------------------------------------------------------------------------
   2. CLAIMS_METRIC_DOC_SEARCH — over SEMANTIC.METRIC_REGISTRY + DATA_DICTIONARY
   -----------------------------------------------------------------------------
   Grounds the agent in CERTIFIED metric definitions and column documentation so
   it answers "what is PMPM and how is it calculated?" from governed docs, not
   hallucination. We UNION metric docs and dictionary entries into one corpus.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE CORTEX SEARCH SERVICE CLAIMS_METRIC_DOC_SEARCH
  ON search_text
  ATTRIBUTES doc_type, name, owner, certified_status
  WAREHOUSE = WH_CLAIMS_MCP
  TARGET_LAG = '1 hour'
  COMMENT = 'Search over certified metric definitions + data dictionary (grounds NL answers in governed docs).'
AS
  SELECT
    'METRIC' AS doc_type,
    metric_name AS name,
    owner,
    certified_status,
    metric_name || ': ' || COALESCE(business_definition,'') || ' (grain: ' ||
      COALESCE(grain,'') || '; source: ' || COALESCE(source_model,'') || ')' AS search_text
  FROM SEMANTIC.METRIC_REGISTRY
  UNION ALL
  SELECT
    'DICTIONARY' AS doc_type,
    object_name || '.' || column_name AS name,
    NULL AS owner,
    NULL AS certified_status,
    object_name || '.' || column_name || ': ' || COALESCE(description,'') ||
      ' (type: ' || COALESCE(data_type,'') || ')' AS search_text
  FROM SEMANTIC.DATA_DICTIONARY;

/* -----------------------------------------------------------------------------
   3. CLAIMS_DATA_QUALITY_SEARCH — over DQ results + quarantine summaries + runbook
   -----------------------------------------------------------------------------
   Operational/triage corpus: lets an operator (or the agent) ask "what DQ checks
   are failing on the claim pipeline and what's the runbook?" We index a SUMMARY
   of quarantine (NOT the sensitive payload) plus DQ results and runbook entries.
   --------------------------------------------------------------------------- */
CREATE OR REPLACE CORTEX SEARCH SERVICE CLAIMS_DATA_QUALITY_SEARCH
  ON search_text
  ATTRIBUTES doc_type, ref_id, severity, status
  WAREHOUSE = WH_CLAIMS_MCP
  TARGET_LAG = '1 hour'
  COMMENT = 'Search over DQ failures + quarantine summaries (no payloads) + operational runbook.'
AS
  -- DQ test outcomes
  SELECT
    'DQ_RESULT' AS doc_type,
    dq_result_id AS ref_id,
    severity,
    status,
    'DQ ' || COALESCE(model_name,'') || ' / ' || COALESCE(test_name,'') ||
      ' -> ' || COALESCE(status,'') || ' (' || COALESCE(failed_row_count::string,'0') || ' failed rows)' AS search_text
  FROM AUDIT.DATA_QUALITY_RESULT
  UNION ALL
  -- Quarantine SUMMARIES only (reason + key + status; never the raw payload)
  SELECT
    'QUARANTINE' AS doc_type,
    quarantine_id AS ref_id,
    'WARN' AS severity,
    quarantine_status AS status,
    'Quarantine ' || COALESCE(source_table,'') || ' key=' || COALESCE(natural_key,'') ||
      ' reason=' || COALESCE(quarantine_reason,'') AS search_text
  FROM AUDIT.QUARANTINE_RECORD
  UNION ALL
  -- Operational runbook entries
  SELECT
    'RUNBOOK' AS doc_type,
    runbook_id AS ref_id,
    NULL AS severity,
    NULL AS status,
    title || ': ' || COALESCE(content,'') AS search_text
  FROM SEMANTIC.CLAIMS_RUNBOOK;

/* -----------------------------------------------------------------------------
   GRANTS — the MCP reader / agent role needs USAGE on the search services.
   --------------------------------------------------------------------------- */
GRANT USAGE ON CORTEX SEARCH SERVICE CLAIMS_PROVIDER_SEARCH     TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON CORTEX SEARCH SERVICE CLAIMS_METRIC_DOC_SEARCH   TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON CORTEX SEARCH SERVICE CLAIMS_DATA_QUALITY_SEARCH TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON CORTEX SEARCH SERVICE CLAIMS_PROVIDER_SEARCH     TO ROLE CLAIMS_ANALYST;
GRANT USAGE ON CORTEX SEARCH SERVICE CLAIMS_METRIC_DOC_SEARCH   TO ROLE CLAIMS_ANALYST;

/* DONE. Indexes build asynchronously; first refresh runs on WH_CLAIMS_MCP. */
