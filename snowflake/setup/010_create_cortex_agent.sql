/* =============================================================================
   010_create_cortex_agent.sql
   snowflake-claims-platform :: Cortex Agent (CLAIMS_AGENT)
   -----------------------------------------------------------------------------
   GOAL
     Define CORTEX.CLAIMS_AGENT — an orchestrating agent that combines:
       1. Cortex Analyst  : text-to-SQL grounded by the SEMANTIC VIEW / semantic
                            model (see script 012) over GOLD/SEMANTIC.
       2. Cortex Search   : the 3 services from script 009 (provider / metric-doc
                            / data-quality) for retrieval + entity resolution.
       3. Read-only SQL   : a constrained SQL execution tool that runs ONLY as
                            CLAIMS_MCP_READER (SELECT-only surface from 011).

   GA / DDL CAVEAT
     The CREATE AGENT DDL surface is evolving and may not be GA in every account.
     If `CREATE AGENT` is unavailable in your account, this file's object spec is
     authoritative: create the agent in Snowsight (AI & ML > Agents) or via the
     Cortex Agents REST API, copying the tool bindings + instructions below.
     The DDL block is wrapped so the script does not abort if DDL is unsupported.

   SECURITY POSTURE (enforced via instructions + the MCP_READER role from 011)
     - Prefer CERTIFIED GOLD / SEMANTIC objects.
     - NEVER query BRONZE / RAW / CONTROL internals / full quarantine payloads.
     - NEVER issue DDL or DML (SELECT-only).
     - NEVER `SELECT *`; always project explicit columns.
     - Always apply a row LIMIT on exploratory queries.
     - CITE the source of every answer (Analyst / Search service / SQL).
     - WARN the user the data is SYNTHETIC (no real PHI).

   RUN AS: CLAIMS_SYSADMIN. Parameterised on $claims_db. IDEMPOTENT.
   ============================================================================= */

SET claims_db = 'CLAIMS_DEV';   -- override: -D claims_db=CLAIMS_PROD

USE ROLE CLAIMS_SYSADMIN;
USE DATABASE IDENTIFIER($claims_db);
USE SCHEMA CORTEX;

/* -----------------------------------------------------------------------------
   AGENT INSTRUCTIONS (reused in the DDL and as the Snowsight/REST config).
   Kept as a single source of truth; copy verbatim if configuring via UI/REST.
   --------------------------------------------------------------------------- */
-- INSTRUCTIONS:
--   You are CLAIMS_AGENT, an analytics assistant for a SYNTHETIC health-claims
--   platform. Always remind users the data is SYNTHETIC (no real PHI/PII).
--   Tool selection:
--     - Use CORTEX ANALYST (semantic model over GOLD/SEMANTIC) for quantitative
--       questions ("paid trend", "PMPM", "denial rate").
--     - Use CORTEX SEARCH (provider / metric-doc / data-quality) to resolve
--       entities, define metrics, or triage data-quality questions.
--     - Use the READ-ONLY SQL tool only when Analyst cannot express the query;
--       it runs as CLAIMS_MCP_READER and can ONLY SELECT from approved
--       GOLD/SEMANTIC/MCP_* views.
--   Hard rules:
--     - SELECT-only. Never DDL/DML. Never modify data.
--     - Never query BRONZE, RAW, CONTROL internals, or full QUARANTINE payloads.
--     - Prefer CERTIFIED metrics/objects (certified_status='CERTIFIED').
--     - Never SELECT *; project explicit columns.
--     - Always add a LIMIT to exploratory result sets (default 100).
--     - Cite which tool/source produced each answer.
--     - If a request needs blocked data, refuse and explain the boundary.

/* -----------------------------------------------------------------------------
   AGENT DEFINITION (DDL form). Wrapped so unsupported-DDL accounts don't abort.
   Tool bindings reference: the semantic view (012), the 3 search services (009),
   and a SQL_EXEC tool bound to CLAIMS_MCP_READER.
   --------------------------------------------------------------------------- */
EXECUTE IMMEDIATE $$
BEGIN
  CREATE OR REPLACE AGENT CORTEX.CLAIMS_AGENT
    COMMENT = 'Claims analytics agent (SYNTHETIC data). Analyst + Search + read-only SQL. SELECT-only; certified GOLD/SEMANTIC only.'
    WITH PROFILE = '{ "display_name": "Claims Analytics Agent" }'
    FROM SPECIFICATION $SPEC$
    {
      "models": { "orchestration": "auto" },
      "instructions": {
        "response": "Answer concisely. Always state that data is SYNTHETIC. Cite the tool used (Analyst/Search/SQL).",
        "orchestration": "Prefer Cortex Analyst for quantitative questions. Use Search to resolve entities or define metrics. Use the SQL tool only when Analyst cannot express the query.",
        "system": "SELECT-only. Never DDL/DML. Never query BRONZE/RAW/CONTROL internals or full quarantine payloads. Prefer certified GOLD/SEMANTIC objects. Never SELECT *. Always LIMIT exploratory queries. Cite sources. Warn data is synthetic."
      },
      "tools": [
        { "tool_spec": { "type": "cortex_analyst_text_to_sql", "name": "claims_analyst",
            "description": "Quantitative claims questions grounded by the semantic view over GOLD/SEMANTIC." } },
        { "tool_spec": { "type": "cortex_search", "name": "provider_search",
            "description": "Resolve provider mentions to provider_id." } },
        { "tool_spec": { "type": "cortex_search", "name": "metric_doc_search",
            "description": "Look up certified metric definitions and the data dictionary." } },
        { "tool_spec": { "type": "cortex_search", "name": "data_quality_search",
            "description": "Triage data-quality failures and the operational runbook." } },
        { "tool_spec": { "type": "sql_exec", "name": "readonly_sql",
            "description": "Run read-only SELECT as CLAIMS_MCP_READER on approved views only." } }
      ],
      "tool_resources": {
        "claims_analyst":      { "semantic_view": "CLAIMS_DEV.SEMANTIC.CLAIMS_SEMANTIC_VIEW" },
        "provider_search":     { "name": "CLAIMS_DEV.CORTEX.CLAIMS_PROVIDER_SEARCH",     "max_results": 5 },
        "metric_doc_search":   { "name": "CLAIMS_DEV.CORTEX.CLAIMS_METRIC_DOC_SEARCH",   "max_results": 5 },
        "data_quality_search": { "name": "CLAIMS_DEV.CORTEX.CLAIMS_DATA_QUALITY_SEARCH", "max_results": 5 },
        "readonly_sql":        { "execution_environment": { "type": "warehouse", "warehouse": "WH_CLAIMS_MCP", "query_timeout": 60 } }
      }
    }
    $SPEC$;
  SYSTEM$LOG('info', 'CLAIMS_AGENT created/updated via DDL.');
EXCEPTION
  WHEN OTHER THEN
    -- CREATE AGENT DDL may not be GA in this account. Configure via Snowsight
    -- (AI & ML > Agents) or the Cortex Agents REST API using the spec above.
    SYSTEM$LOG('warn', 'CREATE AGENT DDL not available; configure CLAIMS_AGENT via Snowsight/REST using the spec in this file.');
END;
$$;

/* -----------------------------------------------------------------------------
   GRANTS — let the MCP reader / analyst use the agent (if AGENT objects support
   USAGE grants in this account; wrapped for portability).
   --------------------------------------------------------------------------- */
EXECUTE IMMEDIATE $$
BEGIN
  GRANT USAGE ON AGENT CORTEX.CLAIMS_AGENT TO ROLE CLAIMS_MCP_READER;
  GRANT USAGE ON AGENT CORTEX.CLAIMS_AGENT TO ROLE CLAIMS_ANALYST;
EXCEPTION
  WHEN OTHER THEN
    SYSTEM$LOG('info', 'AGENT USAGE grant skipped (object/grant not available in this account).');
END;
$$;

/* DONE. Agent (or its spec) is defined; consumed by Snowflake-managed MCP (011). */
