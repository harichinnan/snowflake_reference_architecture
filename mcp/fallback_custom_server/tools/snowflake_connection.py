"""Snowflake connection helper for the FALLBACK custom MCP server.

FALLBACK ONLY. The primary path is the Snowflake-managed MCP server.

Responsibilities
----------------
* Read connection settings from environment (``.env`` supported via
  ``python-dotenv`` loaded in ``server.py``).
* Prefer **key-pair** authentication over passwords.
* Always connect as the least-privilege role ``CLAIMS_MCP_READER`` on warehouse
  ``WH_CLAIMS_MCP`` unless explicitly overridden by env.
* Provide a context-managed cursor.
* Provide a best-effort helper to log every tool call to
  ``AUDIT.MCP_QUERY_LOG``.

All data in this platform is SYNTHETIC. There is no real PHI/PII.
"""

from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any, Iterator, Optional, Sequence

import snowflake.connector
from snowflake.connector.cursor import DictCursor, SnowflakeCursor

logger = logging.getLogger("claims_mcp.connection")

# Sensible defaults that match snowflake/setup/001-003.
_DEFAULT_ROLE = "CLAIMS_MCP_READER"
_DEFAULT_WAREHOUSE = "WH_CLAIMS_MCP"
_DEFAULT_DATABASE = "CLAIMS_DEV"
_DEFAULT_SCHEMA = "SEMANTIC"


@dataclass(frozen=True)
class ConnectionConfig:
    """Resolved Snowflake connection configuration (from env)."""

    account: str
    user: str
    role: str = _DEFAULT_ROLE
    warehouse: str = _DEFAULT_WAREHOUSE
    database: str = _DEFAULT_DATABASE
    schema: str = _DEFAULT_SCHEMA
    # Auth method resolution (in priority order):
    #   1. externalbrowser  (SSO; best for LOCAL DEV — opens a browser to log in)
    #   2. key-pair         (best for HEADLESS / service users)
    #   3. password         (NOT recommended; supported for completeness)
    authenticator: Optional[str] = None  # e.g. "externalbrowser"
    private_key_path: Optional[str] = None
    private_key_passphrase: Optional[str] = None
    password: Optional[str] = None
    query_timeout_seconds: int = 60

    @staticmethod
    def from_env() -> "ConnectionConfig":
        """Build a config from environment variables.

        Required: ``SNOWFLAKE_ACCOUNT``, ``SNOWFLAKE_USER`` and one auth method.

        Auth is resolved as follows:
          * ``SNOWFLAKE_AUTHENTICATOR=externalbrowser`` -> SSO (local dev). No
            key or password needed; the connector opens a browser.
          * else ``SNOWFLAKE_PRIVATE_KEY_PATH`` -> key-pair (headless/service).
          * else ``SNOWFLAKE_PASSWORD`` -> password (not recommended).
        """
        account = _require_env("SNOWFLAKE_ACCOUNT")
        user = _require_env("SNOWFLAKE_USER")

        authenticator = os.getenv("SNOWFLAKE_AUTHENTICATOR")
        private_key_path = os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH")
        password = os.getenv("SNOWFLAKE_PASSWORD")

        is_external_browser = (
            authenticator is not None
            and authenticator.strip().lower() == "externalbrowser"
        )
        if not is_external_browser and not private_key_path and not password:
            raise RuntimeError(
                "No Snowflake auth configured. Set ONE of: "
                "SNOWFLAKE_AUTHENTICATOR=externalbrowser (SSO, local dev), "
                "SNOWFLAKE_PRIVATE_KEY_PATH (key-pair, preferred for headless), "
                "or SNOWFLAKE_PASSWORD (not recommended)."
            )

        return ConnectionConfig(
            account=account,
            user=user,
            role=os.getenv("SNOWFLAKE_ROLE", _DEFAULT_ROLE),
            warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", _DEFAULT_WAREHOUSE),
            database=os.getenv("SNOWFLAKE_DATABASE", _DEFAULT_DATABASE),
            schema=os.getenv("SNOWFLAKE_SCHEMA", _DEFAULT_SCHEMA),
            authenticator=authenticator,
            private_key_path=private_key_path,
            private_key_passphrase=os.getenv("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE"),
            password=password,
            query_timeout_seconds=int(os.getenv("MCP_QUERY_TIMEOUT_SECONDS", "60")),
        )


def _require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Required environment variable {name} is not set.")
    return value


def _load_private_key(path: str, passphrase: Optional[str]) -> bytes:
    """Load and DER-encode an RSA private key for Snowflake key-pair auth."""
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization

    with open(path, "rb") as fh:
        key = serialization.load_pem_private_key(
            fh.read(),
            password=passphrase.encode() if passphrase else None,
            backend=default_backend(),
        )
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


class SnowflakeClient:
    """Thin wrapper that opens short-lived connections per operation.

    We deliberately do not hold a long-lived connection: tool calls are bursty
    and ``WH_CLAIMS_MCP`` auto-suspends. Each call opens, runs, and closes.
    """

    def __init__(self, config: ConnectionConfig) -> None:
        self._config = config

    @property
    def config(self) -> ConnectionConfig:
        return self._config

    def _connect(self) -> snowflake.connector.SnowflakeConnection:
        cfg = self._config
        kwargs: dict[str, Any] = {
            "account": cfg.account,
            "user": cfg.user,
            "role": cfg.role,
            "warehouse": cfg.warehouse,
            "database": cfg.database,
            "schema": cfg.schema,
            "client_session_keep_alive": False,
            # Hard ceiling so a runaway statement cannot burn credits.
            "session_parameters": {
                "STATEMENT_TIMEOUT_IN_SECONDS": cfg.query_timeout_seconds,
            },
        }
        # Auth resolution, same priority as ConnectionConfig.from_env():
        #   externalbrowser (SSO) > key-pair > password.
        if cfg.authenticator and cfg.authenticator.strip().lower() == "externalbrowser":
            # Local-dev SSO: opens a browser for the developer to authenticate.
            # No key/password is sent; requires a machine WITH a browser.
            kwargs["authenticator"] = "externalbrowser"
        elif cfg.private_key_path:
            kwargs["private_key"] = _load_private_key(
                cfg.private_key_path, cfg.private_key_passphrase
            )
        else:
            kwargs["password"] = cfg.password

        logger.debug(
            "Connecting to Snowflake account=%s role=%s wh=%s db=%s",
            cfg.account, cfg.role, cfg.warehouse, cfg.database,
        )
        return snowflake.connector.connect(**kwargs)

    @contextmanager
    def cursor(self, dict_cursor: bool = True) -> Iterator[SnowflakeCursor]:
        """Context-managed cursor. Connection is closed on exit."""
        conn = self._connect()
        try:
            cur = conn.cursor(DictCursor) if dict_cursor else conn.cursor()
            try:
                yield cur
            finally:
                cur.close()
        finally:
            conn.close()

    def run_query(
        self, sql: str, params: Optional[Sequence[Any]] = None
    ) -> list[dict[str, Any]]:
        """Run a read-only query and return rows as dicts.

        NOTE: callers must pass SQL that has already been validated by
        ``tools.safe_sql``. This method does not re-validate.
        """
        with self.cursor(dict_cursor=True) as cur:
            cur.execute(sql, params or [])
            rows = cur.fetchall()
        # DictCursor returns dict-like rows already.
        return [dict(row) for row in rows]

    def log_to_audit(
        self,
        *,
        tool_name: str,
        question: str,
        generated_sql: Optional[str],
        status: str,
        client_name: str = "claims-mcp-fallback",
        row_count: Optional[int] = None,
        error_message: Optional[str] = None,
        snowflake_query_id: Optional[str] = None,
        execution_ms: Optional[int] = None,
    ) -> None:
        """Best-effort write to AUDIT.MCP_QUERY_LOG.

        Column set matches snowflake/setup/006 (MCP_QUERY_LOG):
          query_log_id (PK, NOT NULL), request_ts (default now), client_name,
          user_name, tool_name, question, generated_sql, snowflake_query_id,
          status (SUCCESS|ERROR|BLOCKED), row_count, error_message, execution_ms.

        Logging must never break a tool call, so all failures are swallowed
        (and logged locally). We supply query_log_id (UUID) and let request_ts
        default on the server.
        """
        cfg = self._config
        insert = (
            f"INSERT INTO {cfg.database}.AUDIT.MCP_QUERY_LOG "
            "(query_log_id, client_name, user_name, tool_name, question, "
            " generated_sql, snowflake_query_id, status, row_count, "
            " error_message, execution_ms) "
            "SELECT UUID_STRING(), %s, CURRENT_USER(), %s, %s, %s, %s, %s, "
            "%s, %s, %s"
        )
        try:
            with self.cursor(dict_cursor=False) as cur:
                cur.execute(
                    insert,
                    [
                        client_name,
                        tool_name,
                        question[:8000] if question else None,
                        generated_sql[:8000] if generated_sql else None,
                        snowflake_query_id,
                        status,
                        row_count,
                        error_message[:4000] if error_message else None,
                        execution_ms,
                    ],
                )
        except Exception as exc:  # noqa: BLE001 - logging must never raise
            logger.warning("Failed to write AUDIT.MCP_QUERY_LOG: %s", exc)
