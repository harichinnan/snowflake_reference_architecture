"""Cortex Analyst REST client for the FALLBACK custom MCP server.

FALLBACK ONLY. The primary path is the Snowflake-managed MCP server, which
exposes Cortex Analyst natively. This module lets the *fallback* server still
call Cortex Analyst's REST API directly **if it is enabled in the account**.

Cortex Analyst turns a natural-language question into governed SQL grounded in a
semantic model. We POST the question to the account's
``/api/v2/cortex/analyst/message`` endpoint, pointing at the claims semantic
model file on an internal stage, and return the generated SQL + text answer.

Availability note
-----------------
Cortex Analyst availability depends on the account's edition, region, and Cortex
entitlement. If the endpoint is unavailable / not entitled, this client returns
a clear ``{"available": False, ...}`` payload rather than raising, so the MCP
tool can degrade gracefully and tell the user to use the governed SQL tools or
the managed MCP server instead.

All data in this platform is SYNTHETIC. There is no real PHI/PII.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Optional

import requests

from .snowflake_connection import SnowflakeClient

logger = logging.getLogger("claims_mcp.cortex_analyst")

# Path to the semantic model YAML on an internal stage (set in setup/009).
# e.g. @CLAIMS_DEV.SEMANTIC.SEMANTIC_MODELS/claims_semantic_model.yaml
_DEFAULT_SEMANTIC_MODEL_FILE = (
    "@CLAIMS_DEV.SEMANTIC.SEMANTIC_MODELS/claims_semantic_model.yaml"
)

_ANALYST_PATH = "/api/v2/cortex/analyst/message"


def _account_host(account: str) -> str:
    """Build the Snowflake REST host from the account identifier."""
    host = os.getenv("SNOWFLAKE_HOST")
    if host:
        return host.rstrip("/")
    # account may be ORG-ACCOUNT; the connector convention uses dashes here.
    return f"https://{account}.snowflakecomputing.com"


def _auth_token(client: SnowflakeClient) -> tuple[Optional[str], str]:
    """Obtain a bearer token (and its token-type) for the REST call.

    Order of preference:
      1. ``SNOWFLAKE_PAT`` env -> a Programmatic Access Token. token_type =
         ``PROGRAMMATIC_ACCESS_TOKEN`` (override via ``SNOWFLAKE_TOKEN_TYPE``).
      2. The live session token from an open connector session (works for
         externalbrowser/SSO, key-pair, or password auth). token_type = ``OAUTH``.

    Returns ``(token, token_type)``; ``token`` is ``None`` if none could be got.
    """
    pat = os.getenv("SNOWFLAKE_PAT")
    if pat:
        return pat, os.getenv("SNOWFLAKE_TOKEN_TYPE", "PROGRAMMATIC_ACCESS_TOKEN")
    try:
        # Reuse a connector session to mint a session token. The connector
        # negotiates the configured auth (externalbrowser/JWT/password); we read
        # its REST session token, which Snowflake accepts as an OAUTH token type.
        conn = client._connect()  # noqa: SLF001 - intentional internal reuse
        try:
            token = conn.rest.token  # type: ignore[attr-defined]
            return token, "OAUTH"
        finally:
            conn.close()
    except Exception as exc:  # noqa: BLE001
        logger.warning("Could not obtain a session token for Cortex Analyst: %s", exc)
        return None, "OAUTH"


def ask_cortex_analyst(
    client: SnowflakeClient,
    question: str,
    semantic_model_file: Optional[str] = None,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    """Ask Cortex Analyst a natural-language question.

    Returns a dict:
        { "available": True, "answer": str, "generated_sql": str|None,
          "raw": <api response> }
    or, when Analyst is not usable:
        { "available": False, "reason": str }
    """
    if not question or not question.strip():
        raise ValueError("question is required.")

    semantic_model_file = semantic_model_file or os.getenv(
        "CORTEX_SEMANTIC_MODEL_FILE", _DEFAULT_SEMANTIC_MODEL_FILE
    )

    token, token_type = _auth_token(client)
    if not token:
        return {
            "available": False,
            "reason": (
                "No auth token available for the Cortex Analyst REST API. Set "
                "SNOWFLAKE_PAT or ensure key-pair auth is configured. Prefer the "
                "Snowflake-managed MCP server, which exposes Analyst natively."
            ),
        }

    url = _account_host(client.config.account) + _ANALYST_PATH
    payload = {
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": question.strip()}],
            }
        ],
        "semantic_model_file": semantic_model_file,
    }
    headers = {
        "Authorization": f'Bearer {token}',
        "Content-Type": "application/json",
        "Accept": "application/json",
        # Snowflake expects the token-type header to match the bearer token:
        # PROGRAMMATIC_ACCESS_TOKEN for a PAT, OAUTH for a session token.
        "X-Snowflake-Authorization-Token-Type": token_type,
    }

    try:
        resp = requests.post(url, json=payload, headers=headers, timeout=timeout_seconds)
    except requests.RequestException as exc:
        logger.warning("Cortex Analyst request failed: %s", exc)
        return {
            "available": False,
            "reason": f"Cortex Analyst request failed: {exc}",
        }

    if resp.status_code in (401, 403):
        return {
            "available": False,
            "reason": (
                f"Cortex Analyst auth/authorization failed (HTTP {resp.status_code}). "
                "Check the token and that CLAIMS_MCP_READER may use Cortex."
            ),
        }
    if resp.status_code == 404:
        return {
            "available": False,
            "reason": (
                "Cortex Analyst endpoint not found (HTTP 404). Cortex Analyst is "
                "likely not enabled in this account/region. Use the governed SQL "
                "tools or the Snowflake-managed MCP server."
            ),
        }
    if resp.status_code >= 400:
        return {
            "available": False,
            "reason": f"Cortex Analyst error (HTTP {resp.status_code}): {resp.text[:500]}",
        }

    data = resp.json()
    answer_text, generated_sql = _parse_analyst_response(data)
    return {
        "available": True,
        "answer": answer_text,
        "generated_sql": generated_sql,
        "raw": data,
        "note": "Synthetic data. SQL is generated against the certified semantic model.",
    }


def _parse_analyst_response(data: dict[str, Any]) -> tuple[str, Optional[str]]:
    """Extract the text answer and generated SQL from an Analyst response.

    The Analyst message format returns content blocks of type 'text' and 'sql'.
    We concatenate text blocks and pick the first sql block.
    """
    text_parts: list[str] = []
    sql_stmt: Optional[str] = None
    message = data.get("message", data)
    content = message.get("content", []) if isinstance(message, dict) else []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            text_parts.append(str(block.get("text", "")))
        elif btype == "sql" and sql_stmt is None:
            sql_stmt = block.get("statement") or block.get("sql")
    return ("\n".join(p for p in text_parts if p).strip(), sql_stmt)
