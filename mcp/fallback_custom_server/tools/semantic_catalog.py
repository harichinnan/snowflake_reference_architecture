"""Semantic catalog access for the FALLBACK custom MCP server.

FALLBACK ONLY. The primary path is the Snowflake-managed MCP server.

Exposes the *governed* semantic surface so an AI client can discover what it is
allowed to query and what each metric means — without inventing metric logic.
Logic lives in dbt + SEMANTIC; this module only reads it.

Sources
-------
* ``SEMANTIC.METRIC_REGISTRY``  — one row per certified metric (name, grain,
  definition, owning model, SQL expression reference).
* ``SEMANTIC.DATA_DICTIONARY``  — column-level documentation for exposed views.
* ``INFORMATION_SCHEMA.VIEWS``  — to enumerate the actually-exposed views in the
  allowlisted schemas.

All data in this platform is SYNTHETIC. There is no real PHI/PII.
"""

from __future__ import annotations

import logging
from typing import Any, Optional

from .snowflake_connection import SnowflakeClient

logger = logging.getLogger("claims_mcp.semantic_catalog")

# Schemas whose views are surfaced to the model as "queryable objects".
_EXPOSED_SCHEMAS = ("GOLD", "SEMANTIC", "SILVER_DIMENSIONAL")


def list_semantic_objects(
    client: SnowflakeClient, schema_filter: Optional[str] = None
) -> dict[str, Any]:
    """List approved, queryable semantic objects (views) the reader may use.

    Returns a structured dict with views grouped by schema plus the registered
    metrics. ``schema_filter`` (case-insensitive) narrows to one schema.
    """
    db = client.config.database
    schemas = _EXPOSED_SCHEMAS
    if schema_filter:
        sf = schema_filter.upper()
        if sf not in _EXPOSED_SCHEMAS:
            raise ValueError(
                f"schema_filter '{schema_filter}' is not exposed. "
                f"Choose one of {_EXPOSED_SCHEMAS}."
            )
        schemas = (sf,)

    placeholders = ", ".join(["%s"] * len(schemas))
    views_sql = (
        f"SELECT table_schema, table_name, comment "
        f"FROM {db}.INFORMATION_SCHEMA.VIEWS "
        f"WHERE table_schema IN ({placeholders}) "
        f"ORDER BY table_schema, table_name"
    )
    views = client.run_query(views_sql, list(schemas))

    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in views:
        grouped.setdefault(row["TABLE_SCHEMA"], []).append(
            {"name": row["TABLE_NAME"], "description": row.get("COMMENT")}
        )

    metrics = _safe_list_metrics(client)

    return {
        "database": db,
        "exposed_schemas": list(schemas),
        "views_by_schema": grouped,
        "metrics": metrics,
        "note": "Synthetic data. Metric logic is defined in dbt + SEMANTIC.",
    }


def get_metric_definition(client: SnowflakeClient, metric_name: str) -> dict[str, Any]:
    """Return the registered definition of a single metric.

    Reads ``SEMANTIC.METRIC_REGISTRY``. Raises ``LookupError`` if not found.
    """
    if not metric_name or not metric_name.strip():
        raise ValueError("metric_name is required.")

    db = client.config.database
    sql = (
        f"SELECT * FROM {db}.SEMANTIC.METRIC_REGISTRY "
        f"WHERE UPPER(metric_name) = UPPER(%s) "
        f"LIMIT 1"
    )
    rows = client.run_query(sql, [metric_name.strip()])
    if not rows:
        # Offer near-matches to help the model self-correct.
        suggestions = _suggest_metric_names(client, metric_name)
        raise LookupError(
            f"Metric '{metric_name}' not found in SEMANTIC.METRIC_REGISTRY. "
            + (f"Did you mean: {', '.join(suggestions)}?" if suggestions else "")
        )
    row = rows[0]
    row["note"] = "Synthetic data. Definition is authoritative; do not recompute."
    return row


def _safe_list_metrics(client: SnowflakeClient) -> list[dict[str, Any]]:
    """List metric names + short definitions; tolerate a missing registry."""
    db = client.config.database
    # Column names match SEMANTIC.METRIC_REGISTRY (snowflake/setup/012):
    # metric_name, business_definition, grain, owner, certified_status, ...
    sql = (
        f"SELECT metric_name, grain, certified_status, business_definition "
        f"FROM {db}.SEMANTIC.METRIC_REGISTRY "
        f"ORDER BY metric_name"
    )
    try:
        return client.run_query(sql)
    except Exception as exc:  # noqa: BLE001
        logger.warning("Could not read SEMANTIC.METRIC_REGISTRY: %s", exc)
        return []


def _suggest_metric_names(client: SnowflakeClient, partial: str) -> list[str]:
    db = client.config.database
    sql = (
        f"SELECT metric_name FROM {db}.SEMANTIC.METRIC_REGISTRY "
        f"WHERE metric_name ILIKE %s ORDER BY metric_name LIMIT 5"
    )
    try:
        rows = client.run_query(sql, [f"%{partial.strip()}%"])
        return [r["METRIC_NAME"] for r in rows]
    except Exception:  # noqa: BLE001
        return []
