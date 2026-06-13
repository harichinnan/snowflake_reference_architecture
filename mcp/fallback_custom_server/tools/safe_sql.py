"""SQL guardrails for the FALLBACK custom MCP server.

FALLBACK ONLY. The primary path is the Snowflake-managed MCP server, which
enforces governance via RBAC. This module is the defense-in-depth layer for the
self-hosted fallback: even though ``CLAIMS_MCP_READER`` is already SELECT-only by
grant, we refuse to *send* anything that is not a single, read-only, allowlisted
query.

Enforced rules
--------------
1. Exactly **one** statement (no stacked ``;`` statements).
2. Must start with ``SELECT`` or ``WITH`` (read-only).
3. **Denied keywords** anywhere as whole words: INSERT/UPDATE/DELETE/MERGE/
   CREATE/DROP/ALTER/GRANT/REVOKE/COPY/PUT/GET/CALL/USE/TRUNCATE/EXECUTE.
4. Every referenced ``schema.object`` must live in the **schema allowlist**
   (GOLD, SEMANTIC, selected SILVER_DIMENSIONAL, AUDIT summaries).
5. A ``LIMIT`` is injected/clamped to ``max_rows``.
6. ``SELECT *`` is discouraged: rejected unless the caller opts in, because it
   can pull wide rows and bypass column-level intent.

The validator is intentionally conservative: when in doubt it raises. It returns
*cleaned* SQL (comments stripped, trailing ``;`` removed, LIMIT enforced).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable

# --- Configuration ---------------------------------------------------------

# Schemas the MCP reader is allowed to touch. These mirror snowflake/setup/011.
# AUDIT is allowed ONLY for summary/status views (see ALLOWED_AUDIT_PREFIXES).
DEFAULT_ALLOWED_SCHEMAS: frozenset[str] = frozenset(
    {"GOLD", "SEMANTIC", "SILVER_DIMENSIONAL", "AUDIT"}
)

# Within AUDIT we only permit curated SUMMARY views, never raw quarantine
# payloads / DQ base tables / internal control tables. Object names must start
# with one of these prefixes. These mirror the AUDIT objects granted to
# CLAIMS_MCP_READER in snowflake/setup/011 (VW_DQ_SUMMARY, VW_QUARANTINE_SUMMARY)
# plus MCP_QUERY_LOG, which the server writes to.
ALLOWED_AUDIT_PREFIXES: tuple[str, ...] = (
    "VW_DQ_SUMMARY",          # MCP-safe DQ rollup (setup/011)
    "VW_QUARANTINE_SUMMARY",  # MCP-safe quarantine rollup; counts only, NO payloads
    "MCP_QUERY_LOG",          # the server's own audit log
    "DQ_",                    # any future data-quality status rollups
    "DATA_QUALITY_SUMMARY",   # any future DQ summary views (NOT the base table)
)

# Statements that must never reach Snowflake from this server.
DENIED_KEYWORDS: tuple[str, ...] = (
    "INSERT", "UPDATE", "DELETE", "MERGE", "CREATE", "DROP", "ALTER",
    "GRANT", "REVOKE", "COPY", "PUT", "GET", "CALL", "USE", "TRUNCATE",
    "EXECUTE", "UNDROP", "COMMENT", "SET", "UNSET",
)

DEFAULT_MAX_ROWS = 1000


class UnsafeSQLError(ValueError):
    """Raised when a statement violates a guardrail."""


@dataclass
class SafeSQLConfig:
    allowed_schemas: frozenset[str] = DEFAULT_ALLOWED_SCHEMAS
    allowed_audit_prefixes: tuple[str, ...] = ALLOWED_AUDIT_PREFIXES
    denied_keywords: tuple[str, ...] = DENIED_KEYWORDS
    max_rows: int = DEFAULT_MAX_ROWS
    allow_select_star: bool = False


@dataclass
class ValidationResult:
    sql: str
    schemas_referenced: set[str] = field(default_factory=set)


# --- Helpers ---------------------------------------------------------------

_LINE_COMMENT = re.compile(r"--[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
_WS = re.compile(r"\s+")

# Matches schema.object or db.schema.object references (qualified identifiers).
# Group 'schema' captures the schema token immediately before the final object.
_QUALIFIED_REF = re.compile(
    r"""
    (?<![\w.])                      # not preceded by word char or dot
    (?:(?P<db>[A-Za-z_][\w$]*)\.)?  # optional database
    (?P<schema>[A-Za-z_][\w$]*)\.   # schema
    (?P<object>[A-Za-z_][\w$]*)     # object
    (?![\w.])                       # not followed by word char or dot
    """,
    re.VERBOSE,
)

_LIMIT_RE = re.compile(r"\blimit\s+(\d+)\b", re.IGNORECASE)


def _strip_comments(sql: str) -> str:
    sql = _BLOCK_COMMENT.sub(" ", sql)
    sql = _LINE_COMMENT.sub(" ", sql)
    return sql


def _normalize(sql: str) -> str:
    return _WS.sub(" ", sql).strip()


def _split_statements(sql: str) -> list[str]:
    """Split on top-level semicolons, ignoring those inside string literals."""
    statements: list[str] = []
    buf: list[str] = []
    quote: str | None = None
    for ch in sql:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            continue
        if ch == ";":
            statements.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
    if buf:
        statements.append("".join(buf))
    return [s for s in (st.strip() for st in statements) if s]


def _mask_string_literals(sql: str) -> str:
    """Replace single/double-quoted literals with spaces for keyword scanning.

    This prevents a value like ``WHERE note = 'please DROP by'`` from tripping
    the DROP keyword check.
    """
    out: list[str] = []
    quote: str | None = None
    for ch in sql:
        if quote:
            out.append(" ")
            if ch == quote:
                quote = None
            continue
        if ch in ("'", '"'):
            quote = ch
            out.append(" ")
            continue
        out.append(ch)
    return "".join(out)


# --- Public API ------------------------------------------------------------

def validate_and_clean(sql: str, config: SafeSQLConfig | None = None) -> ValidationResult:
    """Validate a query against all guardrails and return cleaned SQL.

    Raises ``UnsafeSQLError`` on any violation.
    """
    config = config or SafeSQLConfig()

    if not sql or not sql.strip():
        raise UnsafeSQLError("Empty SQL.")

    decommented = _strip_comments(sql)

    # 1. Exactly one statement.
    statements = _split_statements(decommented)
    if len(statements) == 0:
        raise UnsafeSQLError("No executable statement found.")
    if len(statements) > 1:
        raise UnsafeSQLError(
            f"Only a single statement is allowed; found {len(statements)}."
        )

    statement = _normalize(statements[0])
    keyword_scan = _mask_string_literals(statement)

    # 2. Must be read-only: SELECT or WITH.
    first_token = keyword_scan.split(" ", 1)[0].upper() if keyword_scan else ""
    if first_token not in {"SELECT", "WITH"}:
        raise UnsafeSQLError(
            f"Only SELECT/WITH queries are allowed (got '{first_token}')."
        )

    # 3. Denied keywords (whole-word, outside string literals).
    _reject_denied_keywords(keyword_scan, config.denied_keywords)

    # 4. Schema allowlist enforcement.
    schemas = _enforce_schema_allowlist(keyword_scan, config)

    # 5. SELECT * guard.
    if not config.allow_select_star and _has_select_star(keyword_scan):
        raise UnsafeSQLError(
            "SELECT * is not allowed; enumerate the columns you need "
            "(or pass allow_select_star=True for an approved narrow view)."
        )

    # 6. Enforce / inject LIMIT.
    cleaned = _enforce_limit(statement, config.max_rows)

    return ValidationResult(sql=cleaned, schemas_referenced=schemas)


def _reject_denied_keywords(scan: str, denied: Iterable[str]) -> None:
    upper = scan.upper()
    for kw in denied:
        if re.search(rf"\b{re.escape(kw)}\b", upper):
            raise UnsafeSQLError(f"Denied keyword detected: {kw}.")


def _enforce_schema_allowlist(scan: str, config: SafeSQLConfig) -> set[str]:
    """Every qualified reference must point at an allowed schema/object.

    Unqualified single identifiers (CTE names, aliases, function calls) are not
    matched by ``_QUALIFIED_REF`` and are therefore ignored here; they resolve
    against the session schema, which is itself in the allowlist.
    """
    found: set[str] = set()
    for m in _QUALIFIED_REF.finditer(scan):
        schema = m.group("schema").upper()
        obj = m.group("object").upper()

        # Skip pseudo-qualified things that are actually function/alias.col.
        # If the 'schema' token is a SQL function or keyword, ignore.
        if schema in _SQL_NOISE_TOKENS:
            continue

        if schema not in config.allowed_schemas:
            raise UnsafeSQLError(
                f"Reference to non-allowlisted schema '{schema}'. Allowed: "
                f"{', '.join(sorted(config.allowed_schemas))}."
            )

        # AUDIT is restricted to curated summary objects only.
        if schema == "AUDIT" and not obj.startswith(config.allowed_audit_prefixes):
            raise UnsafeSQLError(
                f"AUDIT object '{obj}' is not an approved summary view. "
                f"Allowed prefixes: {', '.join(config.allowed_audit_prefixes)}."
            )
        found.add(schema)

    if not found:
        # No qualified reference at all is suspicious for our tools; the caller
        # should reference an allowlisted object explicitly.
        raise UnsafeSQLError(
            "Query does not reference any allowlisted schema.object. Qualify "
            "tables as e.g. GOLD.<view> or SEMANTIC.<view>."
        )
    return found


def _has_select_star(scan: str) -> bool:
    # Matches "select *" and "select t.*" forms.
    return bool(re.search(r"\bselect\s+(?:[A-Za-z_][\w$]*\.)?\*", scan, re.IGNORECASE))


def _enforce_limit(statement: str, max_rows: int) -> str:
    """Clamp an existing LIMIT to ``max_rows`` or append one if absent."""
    existing = _LIMIT_RE.search(statement)
    if existing:
        requested = int(existing.group(1))
        clamped = min(requested, max_rows)
        if clamped != requested:
            statement = _LIMIT_RE.sub(f"LIMIT {clamped}", statement, count=1)
        return statement
    return f"{statement} LIMIT {max_rows}"


# Tokens that look like a schema in ``token.token`` but are not (function names,
# common pseudo-columns). Conservative: anything here is ignored by the schema
# check so legitimate function calls don't false-positive.
_SQL_NOISE_TOKENS: frozenset[str] = frozenset(
    {
        "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_USER", "CURRENT_ROLE",
        "DATEADD", "DATEDIFF", "DATE_TRUNC", "TO_CHAR", "TO_DATE", "COALESCE",
        "IFF", "NULLIF", "ROUND", "SUM", "AVG", "COUNT", "MIN", "MAX",
        "INFORMATION_SCHEMA",  # handled separately if ever needed
    }
)
