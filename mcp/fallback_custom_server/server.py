"""FALLBACK custom MCP server for snowflake-claims-platform.

================================================================================
FALLBACK ONLY — NOT THE PRIMARY RECOMMENDATION.
The primary, recommended integration is the **Snowflake-managed MCP server**
(see ../README.md). Use this local server ONLY when the managed MCP server is
unavailable in your account.
================================================================================

This is a complete, runnable MCP server built on the official ``mcp`` Python SDK
(``FastMCP``) and the Snowflake Python connector. It exposes a small set of
**read-only** tools over the governed claims data, authenticating as the
least-privilege role ``CLAIMS_MCP_READER`` on warehouse ``WH_CLAIMS_MCP``.

Guardrails (defense in depth on top of RBAC):
  * SELECT/WITH only; single statement.
  * Schema allowlist: GOLD / SEMANTIC / selected SILVER_DIMENSIONAL / AUDIT
    summary views only.
  * Denied keywords (no PUT/GET/COPY/CALL/USE/DDL/DML/account-admin).
  * Row limit injected/clamped; statement timeout enforced.
  * Every tool call is logged best-effort to AUDIT.MCP_QUERY_LOG.

All data in this platform is SYNTHETIC. There is no real PHI/PII.

Run (stdio):
    cd mcp/fallback_custom_server
    cp .env.example .env   # then edit
    python server.py
or via the console script:
    claims-mcp-fallback
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any, Optional

from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP

from tools import cortex_analyst_client, safe_sql, semantic_catalog
from tools.snowflake_connection import ConnectionConfig, SnowflakeClient

# --- Bootstrap -------------------------------------------------------------

load_dotenv()  # load .env if present (no-op otherwise)

logging.basicConfig(
    level=os.getenv("MCP_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("claims_mcp.server")

SYNTHETIC_NOTE = (
    "All data in snowflake-claims-platform is SYNTHETIC; it contains no real "
    "PHI/PII. This is a FALLBACK MCP server; prefer the Snowflake-managed MCP "
    "server when available."
)

MAX_ROWS = int(os.getenv("MCP_MAX_ROWS", "1000"))
QUERY_TIMEOUT_SECONDS = int(os.getenv("MCP_QUERY_TIMEOUT_SECONDS", "60"))

mcp = FastMCP(
    name="snowflake-claims-fallback",
    instructions=(
        "Read-only access to the snowflake-claims-platform governed data "
        "(GOLD / SEMANTIC / selected SILVER_DIMENSIONAL / AUDIT summaries). "
        + SYNTHETIC_NOTE
    ),
)

# A single shared client. Connections are opened per-call (bursty workload).
_client: Optional[SnowflakeClient] = None


def get_client() -> SnowflakeClient:
    global _client
    if _client is None:
        _client = SnowflakeClient(ConnectionConfig.from_env())
    return _client


def _safe_config() -> safe_sql.SafeSQLConfig:
    return safe_sql.SafeSQLConfig(max_rows=MAX_ROWS)


def _ok(payload: Any) -> str:
    """Serialize a successful tool result, always including the synthetic note."""
    if isinstance(payload, dict):
        payload.setdefault("_note", SYNTHETIC_NOTE)
    return json.dumps(payload, default=str, indent=2)


def _run_governed_query(
    *, tool_name: str, question: str, sql: str, allow_select_star: bool = False
) -> str:
    """Validate, execute, and log a governed read-only query.

    Audit status vocabulary matches AUDIT.MCP_QUERY_LOG (snowflake/setup/006):
    SUCCESS | ERROR | BLOCKED.
    """
    client = get_client()
    cfg = _safe_config()
    cfg.allow_select_star = allow_select_star
    try:
        result = safe_sql.validate_and_clean(sql, cfg)
    except safe_sql.UnsafeSQLError as exc:
        client.log_to_audit(
            tool_name=tool_name, question=question, generated_sql=sql,
            status="BLOCKED", error_message=str(exc),
        )
        return _ok({"error": f"Query rejected by guardrail: {exc}"})

    try:
        rows = client.run_query(result.sql)
    except Exception as exc:  # noqa: BLE001
        client.log_to_audit(
            tool_name=tool_name, question=question,
            generated_sql=result.sql, status="ERROR", error_message=str(exc),
        )
        return _ok({"error": f"Query failed: {exc}", "executed_sql": result.sql})

    client.log_to_audit(
        tool_name=tool_name, question=question,
        generated_sql=result.sql, status="SUCCESS", row_count=len(rows),
    )
    return _ok({
        "executed_sql": result.sql,
        "row_count": len(rows),
        "rows": rows,
    })


# --- Tools -----------------------------------------------------------------

@mcp.tool()
def list_semantic_objects(schema: Optional[str] = None) -> str:
    """List the approved, queryable governed objects (views) and registered
    metrics this reader may use.

    Args:
        schema: Optional schema filter (GOLD, SEMANTIC, or SILVER_DIMENSIONAL).
    """
    client = get_client()
    try:
        payload = semantic_catalog.list_semantic_objects(client, schema)
    except Exception as exc:  # noqa: BLE001
        return _ok({"error": str(exc)})
    client.log_to_audit(
        tool_name="list_semantic_objects", question=schema or "(all)",
        generated_sql=None, status="SUCCESS",
    )
    return _ok(payload)


@mcp.tool()
def get_metric_definition(metric_name: str) -> str:
    """Return the certified definition of a single metric from
    SEMANTIC.METRIC_REGISTRY. Use this instead of guessing how a metric is
    computed.

    Args:
        metric_name: The metric name, e.g. 'paid_amount_pmpm'.
    """
    client = get_client()
    try:
        payload = semantic_catalog.get_metric_definition(client, metric_name)
    except (LookupError, ValueError) as exc:
        return _ok({"error": str(exc)})
    except Exception as exc:  # noqa: BLE001
        return _ok({"error": str(exc)})
    client.log_to_audit(
        tool_name="get_metric_definition", question=metric_name,
        generated_sql=None, status="SUCCESS",
    )
    return _ok(payload)


@mcp.tool()
def run_safe_sql(sql: str, allow_select_star: bool = False) -> str:
    """Run an approved read-only SQL query over the governed schemas.

    Only a single SELECT/WITH statement is permitted, referencing the
    allowlisted schemas (GOLD / SEMANTIC / selected SILVER_DIMENSIONAL / AUDIT
    summary views). A LIMIT is enforced. No writes or DDL/DML.

    Args:
        sql: A single SELECT/WITH statement, qualifying tables as e.g.
            GOLD.<view> or SEMANTIC.<view>.
        allow_select_star: Set True only for an approved narrow view where
            SELECT * is acceptable.
    """
    return _run_governed_query(
        tool_name="run_safe_sql",
        question=sql,
        sql=sql,
        allow_select_star=allow_select_star,
    )


# -----------------------------------------------------------------------------
# Convenience tools over the APPROVED MCP-safe views.
#
# These target the curated read-only views created in snowflake/setup/011-012
# (SEMANTIC.MCP_* and AUDIT.VW_*_SUMMARY), which is the exact surface granted to
# CLAIMS_MCP_READER. If your dbt build exposes additional GOLD marts (e.g. a
# payer/plan or condition-cost mart), add a matching MCP-safe view + grant and
# point the corresponding tool at it. Column lists are explicit (never SELECT *).
# -----------------------------------------------------------------------------

@mcp.tool()
def get_provider_utilization(
    specialty: Optional[str] = None, top_n: int = 50
) -> str:
    """Provider utilization / spend summary (paid amounts and claim-line volume
    per provider). Optionally filter by specialty.

    Backed by SEMANTIC.MCP_GOLD_PROVIDER_PAID (an approved MCP-safe view).

    Args:
        specialty: Optional provider specialty to filter on.
        top_n: Max providers to return (clamped to the server row limit).
    """
    limit = max(1, min(int(top_n), MAX_ROWS))
    where = ""
    if specialty:
        # Escape single quotes; the guardrail additionally masks literals before
        # keyword scanning, so an embedded value cannot trip a denied keyword.
        safe_val = specialty.replace("'", "''")
        where = f"WHERE UPPER(specialty) = UPPER('{safe_val}') "
    sql = (
        "SELECT provider_id, provider_name, specialty, "
        "total_paid, claim_lines "
        "FROM SEMANTIC.MCP_GOLD_PROVIDER_PAID "
        f"{where}"
        "ORDER BY total_paid DESC "
        f"LIMIT {limit}"
    )
    return _run_governed_query(
        tool_name="get_provider_utilization",
        question=json.dumps({"specialty": specialty, "top_n": top_n}),
        sql=sql,
    )


@mcp.tool()
def get_payer_plan_summary(plan_type: Optional[str] = None) -> str:
    """Payer / plan paid summary by member plan type (paid + allowed by plan).

    Backed by the certified semantic surface. This reference build exposes plan
    breakdowns via SEMANTIC.CLAIMS_SEMANTIC_VIEW; we aggregate it here. If your
    build adds a dedicated payer/plan mart, point this tool at that MCP-safe view.

    Args:
        plan_type: Optional member plan type to filter on (e.g. 'HMO', 'PPO').
    """
    where = ""
    if plan_type:
        safe_val = plan_type.replace("'", "''")
        where = f"WHERE UPPER(plan_type) = UPPER('{safe_val}') "
    sql = (
        "SELECT plan_type, "
        "COUNT(DISTINCT claim_id) AS claim_count, "
        "SUM(paid_amount) AS total_paid, "
        "SUM(allowed_amount) AS total_allowed "
        "FROM SEMANTIC.CLAIMS_SEMANTIC_VIEW "
        f"{where}"
        "GROUP BY plan_type "
        "ORDER BY total_paid DESC"
    )
    return _run_governed_query(
        tool_name="get_payer_plan_summary",
        question=json.dumps({"plan_type": plan_type}),
        sql=sql,
    )


@mcp.tool()
def get_condition_cost_summary(diagnosis_code: Optional[str] = None) -> str:
    """Cost-by-condition summary: claim counts and paid amounts grouped by the
    primary diagnosis code. Optionally filter by diagnosis code.

    Backed by SEMANTIC.MCP_FACT_CLAIM_LINE (an approved MCP-safe view).

    Args:
        diagnosis_code: Optional primary diagnosis code to filter on.
    """
    where = ""
    if diagnosis_code:
        safe_val = diagnosis_code.replace("'", "''")
        where = f"WHERE UPPER(primary_diagnosis_code) = UPPER('{safe_val}') "
    sql = (
        "SELECT primary_diagnosis_code, "
        "COUNT(*) AS claim_line_count, "
        "COUNT(DISTINCT claim_id) AS claim_count, "
        "SUM(paid_amount) AS total_paid, "
        "AVG(paid_amount) AS avg_paid_per_line "
        "FROM SEMANTIC.MCP_FACT_CLAIM_LINE "
        f"{where}"
        "GROUP BY primary_diagnosis_code "
        "ORDER BY total_paid DESC"
    )
    return _run_governed_query(
        tool_name="get_condition_cost_summary",
        question=json.dumps({"diagnosis_code": diagnosis_code}),
        sql=sql,
    )


@mcp.tool()
def get_data_quality_status() -> str:
    """Latest data-quality status rollup from the approved AUDIT summary view
    (test counts / failed rows by model, severity, and status). Does NOT expose
    raw quarantine payloads.

    Backed by AUDIT.VW_DQ_SUMMARY (the MCP-safe DQ rollup from setup/011).
    """
    sql = (
        "SELECT check_day, model_name, severity, status, "
        "test_count, failed_rows "
        "FROM AUDIT.VW_DQ_SUMMARY "
        "ORDER BY check_day DESC, model_name"
    )
    return _run_governed_query(
        tool_name="get_data_quality_status",
        question="data_quality_status",
        sql=sql,
    )


@mcp.tool()
def ask_cortex_analyst(question: str) -> str:
    """Ask Cortex Analyst a natural-language question about the claims data.

    Returns generated SQL + a text answer grounded in the certified semantic
    model, IF Cortex Analyst is enabled in this account. Otherwise returns a
    clear 'not enabled' message — fall back to the governed SQL tools or the
    Snowflake-managed MCP server.

    Args:
        question: A natural-language analytics question.
    """
    client = get_client()
    try:
        result = cortex_analyst_client.ask_cortex_analyst(
            client, question, timeout_seconds=QUERY_TIMEOUT_SECONDS
        )
    except ValueError as exc:
        return _ok({"error": str(exc)})
    except Exception as exc:  # noqa: BLE001
        return _ok({"error": f"Cortex Analyst call failed: {exc}"})

    status = "SUCCESS" if result.get("available") else "ERROR"
    client.log_to_audit(
        tool_name="ask_cortex_analyst", question=question,
        generated_sql=result.get("generated_sql"), status=status,
        error_message=None if result.get("available") else result.get("reason"),
    )
    return _ok(result)


# --- Entry point -----------------------------------------------------------

def main() -> None:
    """Run the MCP server over stdio."""
    logger.info("Starting snowflake-claims fallback MCP server (stdio). %s", SYNTHETIC_NOTE)
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
