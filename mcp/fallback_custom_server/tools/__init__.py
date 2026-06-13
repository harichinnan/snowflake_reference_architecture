"""Tool modules for the FALLBACK custom MCP server.

FALLBACK ONLY. The primary path is the Snowflake-managed MCP server.
All data in this platform is SYNTHETIC. There is no real PHI/PII.
"""

from . import (  # noqa: F401
    cortex_analyst_client,
    safe_sql,
    semantic_catalog,
    snowflake_connection,
)
