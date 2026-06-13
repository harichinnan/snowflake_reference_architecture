# Fallback custom MCP server — snowflake-claims-platform

> ## FALLBACK ONLY — NOT the primary recommendation
> The **primary, recommended** integration is the **Snowflake-managed MCP
> server** (see [`../README.md`](../README.md)). Use this local server **only**
> when the managed MCP server is unavailable in your account (Cortex / managed
> MCP not yet enabled, an air-gapped dev box, or while you wait on enablement).
>
> The deprecated Snowflake-Labs `mcp` package is **not** used here and is **not**
> recommended.

> **Synthetic data.** Everything served is machine-generated. There is **no real
> PHI/PII**.

This is a small, self-hosted MCP server built on the **official `mcp` Python
SDK** (`FastMCP`) plus the **Snowflake Python connector**. It authenticates as
the least-privilege role **`CLAIMS_MCP_READER`** on warehouse
**`WH_CLAIMS_MCP`** and exposes only **read-only** tools over the governed
claims data.

---

## Guardrails (defense in depth on top of RBAC)

Even though `CLAIMS_MCP_READER` is already SELECT-only by grant, the server
refuses to *send* anything that is not safe:

- **SELECT/WITH only**, exactly **one** statement (no stacked `;`).
- **Schema allowlist:** `GOLD`, `SEMANTIC`, selected `SILVER_DIMENSIONAL`, and
  **selected `AUDIT` summary views only** (prefixes `MCP_`, `DQ_`,
  `DATA_QUALITY`). No `RAW`/`BRONZE`/`CONTROL` internals, no full quarantine
  payloads.
- **Denied keywords:** `INSERT/UPDATE/DELETE/MERGE/CREATE/DROP/ALTER/GRANT/
  REVOKE/COPY/PUT/GET/CALL/USE/TRUNCATE/EXECUTE` (and account-admin verbs). No
  writes, no DDL/DML.
- **Row limit** injected/clamped (`MCP_MAX_ROWS`, default 1000).
- **Query timeout** enforced via session `STATEMENT_TIMEOUT_IN_SECONDS`.
- `SELECT *` rejected unless explicitly opted in for an approved narrow view.
- **Audit:** every tool call is logged best-effort to `AUDIT.MCP_QUERY_LOG`
  (tool name, request, executed SQL, status, row count, error).

The guardrail logic lives in [`tools/safe_sql.py`](tools/safe_sql.py); it strips
comments, masks string literals before keyword scanning (so a value like
`'please DROP later'` does not trip the DROP check), splits/validates statements,
enforces the schema allowlist, and clamps the `LIMIT`.

---

## Tools exposed

| Tool | What it does | Backing object |
|---|---|---|
| `list_semantic_objects` | Lists approved queryable views + registered metrics. | `INFORMATION_SCHEMA.VIEWS`, `SEMANTIC.METRIC_REGISTRY` |
| `get_metric_definition` | Returns the certified definition of one metric. | `SEMANTIC.METRIC_REGISTRY` |
| `run_safe_sql` | Runs an approved read-only SELECT/WITH over allowlisted schemas. | any allowlisted view |
| `get_provider_utilization` | Provider paid-amount / claim-line summary (optional specialty filter). | `SEMANTIC.MCP_GOLD_PROVIDER_PAID` |
| `get_payer_plan_summary` | Paid/allowed by member plan type (optional plan filter). | `SEMANTIC.CLAIMS_SEMANTIC_VIEW` |
| `get_condition_cost_summary` | Claims/paid by primary diagnosis code (optional filter). | `SEMANTIC.MCP_FACT_CLAIM_LINE` |
| `get_data_quality_status` | DQ status rollup by model/severity/status (no quarantine payloads). | `AUDIT.VW_DQ_SUMMARY` |
| `ask_cortex_analyst` | NL → governed SQL + answer via the Cortex Analyst REST API, **if enabled**; otherwise returns a clear "not enabled" message. | Cortex Analyst + `SEMANTIC` model |

> These backing objects are the exact MCP-safe views created and granted in
> `snowflake/setup/011`–`012` (`SEMANTIC.MCP_*`, `AUDIT.VW_*_SUMMARY`,
> `SEMANTIC.CLAIMS_SEMANTIC_VIEW`). If your dbt build exposes additional GOLD
> marts (e.g. a dedicated payer/plan or condition-cost mart), create a matching
> MCP-safe view + grant to `CLAIMS_MCP_READER` and point the tool (or
> `run_safe_sql`) at it. Every tool projects explicit columns — never `SELECT *`.

---

## Layout

```
fallback_custom_server/
├── README.md                      ← you are here
├── pyproject.toml                 ← deps + console script (claims-mcp-fallback)
├── .env.example                   ← copy to .env and fill in
├── server.py                      ← FastMCP server; registers all tools
└── tools/
    ├── __init__.py
    ├── snowflake_connection.py    ← connector (key-pair preferred) + audit log
    ├── safe_sql.py                ← SQL guardrails
    ├── semantic_catalog.py        ← list objects / metric definitions
    └── cortex_analyst_client.py   ← Cortex Analyst REST client (if enabled)
```

---

## Prerequisites

1. Snowflake bootstrap applied: `snowflake/setup/001`–`004` (creates
   `CLAIMS_MCP_READER`, `WH_CLAIMS_MCP`, schemas) and `011` (the read-only grant
   surface for the reader). See [`../README.md`](../README.md) §5.
2. A service user whose `DEFAULT_ROLE` is `CLAIMS_MCP_READER`, ideally with
   **key-pair** auth (RSA `.p8`). Passwords work but are not recommended.
3. Python **>= 3.10**.

---

## Install & run

```bash
cd mcp/fallback_custom_server

# Recommended: isolated env
python -m venv .venv && source .venv/bin/activate
pip install -e .          # installs deps + the claims-mcp-fallback script

cp .env.example .env      # then edit: account, user, key path, etc.

# Run over stdio (what an MCP client launches):
python server.py
# or
claims-mcp-fallback
```

### Auth options in `.env`

Set **one** of the following (priority order: externalbrowser → key-pair →
password):

```bash
# 1) externalbrowser (SSO) — best for LOCAL DEV. Opens a browser to log in.
#    Requires a machine WITH a browser (not headless).
SNOWFLAKE_AUTHENTICATOR=externalbrowser
SNOWFLAKE_USER=your.sso.login@example.com

# 2) key-pair — best for HEADLESS / service users (CLAIMS_MCP_SERVICE_USER).
SNOWFLAKE_PRIVATE_KEY_PATH=/abs/path/rsa_key.p8
# SNOWFLAKE_PRIVATE_KEY_PASSPHRASE=...

# 3) password — supported but NOT recommended.
# SNOWFLAKE_PASSWORD=...
```

`SNOWFLAKE_ACCOUNT` uses the `ORG-ACCOUNT` locator format; `SNOWFLAKE_ROLE`
defaults to `CLAIMS_MCP_READER` and `SNOWFLAKE_WAREHOUSE` to `WH_CLAIMS_MCP`.

Point a client at it using the **fallback** block in the configs under
[`../clients/`](../clients/) (set `cwd` to this directory's absolute path). Each
config includes both a key-pair fallback block and an `externalbrowser` (SSO)
fallback block.

> Security: this process holds **live Snowflake credentials** in its
> environment. It is for **local stdio use only** — never expose it behind a
> public URL/tunnel. For a remote endpoint, use the Snowflake-managed MCP server.
> See [`../clients/chatgpt_remote_mcp_notes.md`](../clients/chatgpt_remote_mcp_notes.md).

---

## Troubleshooting

- **`Required environment variable SNOWFLAKE_ACCOUNT is not set`** → fill `.env`.
- **`No Snowflake auth configured`** → set `SNOWFLAKE_PRIVATE_KEY_PATH` (or
  `SNOWFLAKE_PASSWORD`).
- **`Query rejected by guardrail`** → rewrite as a single SELECT/WITH over an
  allowlisted schema; qualify tables (e.g. `GOLD.<view>`).
- **`Insufficient privileges`** → re-run `snowflake/setup/011`; confirm the view
  is in the approved allowlist.
- **`Cortex Analyst not enabled` / HTTP 404** → Cortex isn't enabled in this
  account/region; use the governed SQL tools or the managed MCP server.
- **Audit rows missing** → `AUDIT.MCP_QUERY_LOG` must exist and be writable by
  `CLAIMS_MCP_READER`; logging is best-effort and never blocks a tool call.
