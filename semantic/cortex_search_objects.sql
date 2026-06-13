/* =============================================================================
   cortex_search_objects.sql
   snowflake-claims-platform :: Cortex Search services
   -----------------------------------------------------------------------------
   Creates three Cortex Search services in the CORTEX schema that power semantic
   retrieval for the Cortex Agent (setup/010) and the Snowflake-managed MCP
   (setup/011):

     CLAIMS_PROVIDER_SEARCH      -> SEMANTIC.PROVIDER_LOOKUP
     CLAIMS_METRIC_DOC_SEARCH    -> SEMANTIC.METRIC_REGISTRY + SEMANTIC.DATA_DICTIONARY
     CLAIMS_DATA_QUALITY_SEARCH  -> SEMANTIC.CLAIMS_RUNBOOK
                                    + AUDIT.DATA_QUALITY_RESULT + AUDIT.QUARANTINE_RECORD

   SYNTHETIC DATA. No real PHI. Provider names/NPIs are fabricated.

   ENABLING CORTEX
     - Cortex Search must be available in the account/region and the deploying
       role needs the SNOWFLAKE.CORTEX_USER database role plus CREATE CORTEX
       SEARCH SERVICE on the CORTEX schema:
           GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE CLAIMS_SYSADMIN;
           GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE CLAIMS_MCP_READER;
     - Each service ATTACHES to WAREHOUSE = WH_CLAIMS_MCP (used to (re)build the
       index) and TARGET_LAG controls how fresh the index stays vs the source.
     - ON <col> is the searchable text column; ATTRIBUTES are filterable/return
       columns; the AS (...) query selects what gets indexed. Source queries hit
       certified SEMANTIC/AUDIT objects only — never RAW/BRONZE, never payloads.

   SOURCE TABLE SHAPES assumed (align to your deployed SEMANTIC tables):
     PROVIDER_LOOKUP(npi, provider_name, specialty, taxonomy_code, provider_type, state)
     METRIC_REGISTRY(metric_name, business_definition, calculation_sql, grain,
                     owner, certified_status, source_model, ...)
     DATA_DICTIONARY(object_name, column_name, description, data_type, notes, ...)
     CLAIMS_RUNBOOK(doc_id, topic, question, answer, tags, ...)
     AUDIT.DATA_QUALITY_RESULT(dq_result_id, model_name, test_name, severity,
                     status, failed_row_count, ...)   (setup/006)
     AUDIT.QUARANTINE_RECORD(quarantine_id, source_table, natural_key,
                     quarantine_reason, quarantine_status, ...)   (setup/006)

   RUN AS: CLAIMS_SYSADMIN. Idempotent (CREATE OR REPLACE; rebuild recomputes).
   ============================================================================= */

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE CLAIMS_PROD;          -- swap to CLAIMS_DEV for the dev deploy
USE SCHEMA CORTEX;

-- Pre-req (run once; harmless if already granted):
-- GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE CLAIMS_SYSADMIN;
-- GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE CLAIMS_MCP_READER;

/* =============================================================================
   1) CLAIMS_PROVIDER_SEARCH  — over SEMANTIC.PROVIDER_LOOKUP
   -----------------------------------------------------------------------------
   Answers "find the cardiology providers", "is NPI X in scope", "providers in
   TX". Search text = a composed provider profile; ATTRIBUTES let the agent
   filter by specialty/state/provider_type and return the NPI.
   ============================================================================= */
CREATE OR REPLACE CORTEX SEARCH SERVICE CORTEX.CLAIMS_PROVIDER_SEARCH
  ON search_text
  ATTRIBUTES npi, provider_name, specialty, taxonomy_code, provider_type, state
  WAREHOUSE = WH_CLAIMS_MCP
  TARGET_LAG = '1 hour'
  COMMENT = 'Cortex Search over synthetic provider directory (resolve provider mentions -> NPI / scope checks).'
  AS
    SELECT
        -- Composite searchable text the model embeds/retrieves on.
        provider_name || ' | NPI ' || npi
          || ' | specialty: ' || COALESCE(specialty, 'unknown')
          || ' | taxonomy: '  || COALESCE(taxonomy_code, 'unknown')
          || ' | type: '      || COALESCE(provider_type, 'unknown')
          || ' | state: '     || COALESCE(state, 'unknown')   AS search_text,
        npi,
        provider_name,
        specialty,
        taxonomy_code,
        provider_type,
        state
    FROM CLAIMS_PROD.SEMANTIC.PROVIDER_LOOKUP;

/* =============================================================================
   2) CLAIMS_METRIC_DOC_SEARCH — over METRIC_REGISTRY + DATA_DICTIONARY
   -----------------------------------------------------------------------------
   Answers definitional questions: "what does paid amount mean?", "how is PMPM
   computed?", "what is the grain of fact_claim_line?". Unions the certified
   metric definitions with the data-dictionary column descriptions into one
   searchable doc corpus. Grounds the agent in GOVERNED docs, not hallucination.
   ============================================================================= */
CREATE OR REPLACE CORTEX SEARCH SERVICE CORTEX.CLAIMS_METRIC_DOC_SEARCH
  ON doc_text
  ATTRIBUTES doc_source, object_name, term, certified_status
  WAREHOUSE = WH_CLAIMS_MCP
  TARGET_LAG = '1 hour'
  COMMENT = 'Cortex Search over certified metric registry + data dictionary (metric/definition Q&A). Synthetic.'
  AS
    -- Certified metric definitions
    SELECT
        'METRIC: ' || metric_name
          || '. Definition: '  || COALESCE(business_definition, '')
          || '. Calculation: ' || COALESCE(calculation_sql, '')
          || '. Grain: '       || COALESCE(grain, '')
          || '. Source: '      || COALESCE(source_model, '')   AS doc_text,
        'METRIC_REGISTRY'                                       AS doc_source,
        metric_name                                            AS object_name,
        metric_name                                            AS term,
        certified_status                                       AS certified_status
    FROM CLAIMS_PROD.SEMANTIC.METRIC_REGISTRY
    UNION ALL
    -- Data dictionary table/column descriptions
    SELECT
        'DICTIONARY: ' || object_name
          || COALESCE('.' || column_name, '')
          || ' (' || COALESCE(data_type, 'n/a') || '). '
          || COALESCE(description, '')
          || COALESCE('. Notes: ' || notes, '')                AS doc_text,
        'DATA_DICTIONARY'                                       AS doc_source,
        object_name                                            AS object_name,
        COALESCE(column_name, object_name)                     AS term,
        NULL                                                   AS certified_status
    FROM CLAIMS_PROD.SEMANTIC.DATA_DICTIONARY;

/* =============================================================================
   3) CLAIMS_DATA_QUALITY_SEARCH — runbook + AUDIT DQ + quarantine SUMMARIES
   -----------------------------------------------------------------------------
   Answers operational/DQ questions: "why did last month's paid change?", "what
   is quarantined and why?", "what does this quality failure mean?". Unions the
   runbook Q&A with AUDIT DQ results + quarantine SUMMARIES (reason/key/status —
   never the sensitive payload). AUDIT object/columns per setup/006.
   ============================================================================= */
CREATE OR REPLACE CORTEX SEARCH SERVICE CORTEX.CLAIMS_DATA_QUALITY_SEARCH
  ON doc_text
  ATTRIBUTES doc_source, topic, tags, ref_id, status
  WAREHOUSE = WH_CLAIMS_MCP
  TARGET_LAG = '30 minutes'
  COMMENT = 'Cortex Search over runbook + AUDIT DQ/quarantine summaries (operations & DQ Q&A). No payloads. Synthetic.'
  AS
    -- Runbook Q&A docs
    SELECT
        'RUNBOOK [' || topic || ']: Q: ' || question
          || ' A: ' || answer                                  AS doc_text,
        'CLAIMS_RUNBOOK'                                       AS doc_source,
        topic                                                 AS topic,
        tags                                                  AS tags,
        doc_id                                                AS ref_id,
        NULL                                                  AS status
    FROM CLAIMS_PROD.SEMANTIC.CLAIMS_RUNBOOK
    UNION ALL
    -- AUDIT data-quality result summaries
    SELECT
        'DQ RESULT: model ' || COALESCE(model_name, '')
          || ', test ' || COALESCE(test_name, '')
          || ', status ' || COALESCE(status, '')
          || ', severity ' || COALESCE(severity, '')
          || ', ' || COALESCE(failed_row_count::STRING, '0') || ' failing rows' AS doc_text,
        'AUDIT.DATA_QUALITY_RESULT'                            AS doc_source,
        test_name                                             AS topic,
        model_name                                            AS tags,
        dq_result_id                                          AS ref_id,
        status                                                AS status
    FROM CLAIMS_PROD.AUDIT.DATA_QUALITY_RESULT
    UNION ALL
    -- AUDIT quarantine SUMMARIES (reason + key + status; NEVER the raw payload).
    SELECT
        'QUARANTINE: source ' || COALESCE(source_table, '')
          || ', key ' || COALESCE(natural_key, '')
          || ', reason ' || COALESCE(quarantine_reason, '')
          || ', status ' || COALESCE(quarantine_status, '')   AS doc_text,
        'AUDIT.QUARANTINE_RECORD'                             AS doc_source,
        quarantine_reason                                     AS topic,
        source_table                                          AS tags,
        quarantine_id                                         AS ref_id,
        quarantine_status                                     AS status
    FROM CLAIMS_PROD.AUDIT.QUARANTINE_RECORD;

/* -----------------------------------------------------------------------------
   USAGE grants so the MCP reader / agent can query the search services.
   --------------------------------------------------------------------------- */
GRANT USAGE ON CORTEX SEARCH SERVICE CORTEX.CLAIMS_PROVIDER_SEARCH     TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON CORTEX SEARCH SERVICE CORTEX.CLAIMS_METRIC_DOC_SEARCH   TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON CORTEX SEARCH SERVICE CORTEX.CLAIMS_DATA_QUALITY_SEARCH TO ROLE CLAIMS_MCP_READER;
GRANT USAGE ON CORTEX SEARCH SERVICE CORTEX.CLAIMS_PROVIDER_SEARCH     TO ROLE CLAIMS_ANALYST;
GRANT USAGE ON CORTEX SEARCH SERVICE CORTEX.CLAIMS_METRIC_DOC_SEARCH   TO ROLE CLAIMS_ANALYST;

/* Query example (commented):
   -- SELECT * FROM TABLE(
   --   CORTEX.CLAIMS_METRIC_DOC_SEARCH('how is PMPM computed?', { 'limit': 3 }));
   -- Indexes build asynchronously; first refresh runs on WH_CLAIMS_MCP.
*/
