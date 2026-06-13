# MCP layer — snowflake-claims-platform

> **Synthetic data.** Every record exposed through this MCP layer is
> machine-generated. It is **not** real CMS/Medicare/Medicaid data and contains
> **no PHI/PII**. The RBAC and guardrails below still mirror a production
> HIPAA-grade design so the patterns are faithful.

This directory wires AI clients (Claude Desktop, Cursor, VS Code, and — through a
supported connector path — ChatGPT) to the claims platform's **governed** data
and AI services. The MCP layer is a **read-only access layer**: it surfaces logic
that already lives in dbt, the semantic models, and the GOLD marts. It does not
contain business logic of its own.

---

## 1. Preferred approach — the Snowflake-managed MCP server (PRIMARY)

The **primary, recommended** way to expose this platform to AI clients is the
**Snowflake-managed MCP server**. Snowflake hosts the MCP endpoint inside your
account and exposes, through a single governed surface:

- **Cortex Analyst** — governed natural-language-to-SQL over the claims semantic
  model.
- **Cortex Search** services — retrieval over docs / lookups / unstructured text.
- **Cortex Agents** — tool orchestration that combines Analyst + Search + SQL.
- **Approved read-only SQL** over `GOLD`, `SEMANTIC`, and selected
  `SILVER_DIMENSIONAL` (and selected `AUDIT` summary views).

Why managed is primary:

- Snowflake performs **token authentication, RBAC enforcement, query governance,
  and logging** — you do not hand-roll any of it.
- Credentials never sit in a local process; clients present **short-lived
  tokens** per request.
- It is the only supported path to expose a **remote** endpoint (e.g. to ChatGPT
  connectors) safely.

> **Legacy / deprecated:** the **Snowflake-Labs `mcp` package** is **deprecated**
> and is **not** the recommended approach. Mentioned here only so you recognize it
> in older material; do not build on it.

> **Fallback:** the local custom server in
> [`fallback_custom_server/`](fallback_custom_server/) is a **fallback path only**,
> for accounts/environments where the managed MCP server is not yet available. See
> §6.

### Architecture chain

```
MCP client (Claude Desktop / Cursor / VS Code / ChatGPT via connector)
      │  (MCP over stdio bridge, or remote HTTP/SSE)
      ▼
Snowflake-managed MCP server  (auth as CLAIMS_MCP_READER, on WH_CLAIMS_MCP)
      │
      ├─► Cortex Analyst   (NL → governed SQL over the claims semantic model)
      ├─► Cortex Search    (docs / lookup / unstructured retrieval)
      ├─► Cortex Agents    (orchestrates Analyst + Search + approved SQL)
      └─► Approved read-only SQL (GOLD / SEMANTIC / selected SILVER_DIMENSIONAL / AUDIT summaries)
      │
      ▼
CLAIMS_DEV / CLAIMS_PROD   (data governed by dbt + semantic models; RBAC enforced)
```

---

## 2. When to use Analyst vs. Search vs. Agent

| Service | Use it when… | Don't use it for… |
|---|---|---|
| **Cortex Analyst** | The question is about **governed metrics / structured data** and you want **NL-to-SQL** answered against the certified semantic model (e.g. "average paid amount per provider specialty by month"). Answers are grounded in the semantic model's metrics, dimensions, and synonyms. | Free-text document lookup; questions whose answer is not a metric/dimension in the semantic model. |
| **Cortex Search** | You need **retrieval over docs / lookups / unstructured text** — the data dictionary, metric definitions, runbooks, provider/payer reference lookups, code descriptions. Returns relevant passages/rows, not a computed metric. | Computing aggregations or joins over fact tables (that is Analyst/SQL). |
| **Cortex Agent** | The task needs **orchestration** — deciding *when* to call Analyst, *when* to call Search, and *when* to run approved SQL, then combining the results into one answer (e.g. "Explain the spike in inpatient cost for cardiology in Q3 and cite the metric definition"). | Simple single-step questions — call Analyst or Search directly; the Agent adds latency/cost. |

Rule of thumb: **structured metric → Analyst; text/lookup → Search; multi-step
reasoning that needs both → Agent.**

---

## 3. How MCP fits with dbt + semantic models

The platform is layered; **logic lives upstream of MCP**:

- **dbt** builds `BRONZE → SILVER_CANONICAL → SILVER_DIMENSIONAL → GOLD`. All
  cleaning, conforming, dedupe, and metric *computation* happen here.
- **`SEMANTIC`** holds the semantic model (metrics, dimensions, synonyms) plus the
  `METRIC_REGISTRY` and `DATA_DICTIONARY`. Metrics are **defined once** here and
  reused by Cortex Analyst and Workbooks.
- **`GOLD`** holds the certified, query-ready marts.
- **MCP** is the **access layer**: it lets an AI client *read* those governed
  products and *call* Cortex services over them. **MCP adds no business logic.**
  If a metric is wrong, you fix it in dbt/semantic — not in MCP.

This separation is what keeps answers consistent across BI, Cortex, and AI
clients: there is one definition of "paid amount", one of "provider
utilization", etc.

---

## 4. Security model (least privilege)

- **Single narrow role: `CLAIMS_MCP_READER`.** The managed MCP server (and the
  fallback server) authenticate as this role and nothing else.
- **Scope — `SELECT` only on:**
  - `GOLD` — certified marts.
  - `SEMANTIC` — semantic view, `METRIC_REGISTRY`, `DATA_DICTIONARY`, lookups.
  - **Selected** `SILVER_DIMENSIONAL` views (conformed dims/facts approved for
    exposure).
  - **Selected** `AUDIT` **summary** views (e.g. data-quality status rollups).
- **Explicitly NOT readable:** `RAW` / `BRONZE`, `CONTROL` internals, and **full
  quarantine payloads** in `AUDIT`. Only curated summaries are exposed.
- **No writes, no DDL/DML.** No `INSERT/UPDATE/DELETE/MERGE/CREATE/DROP/ALTER/
  GRANT/COPY/PUT/GET/CALL/USE/TRUNCATE`. The fallback server enforces this with a
  SQL guardrail; the managed server enforces it via RBAC + governance.
- **Compute:** `WH_CLAIMS_MCP` (XSMALL, auto-suspend 60s, 600s statement timeout)
  isolates LLM-driven query cost from analysts/transforms.
- **Auditability:** every fallback-server call is logged (best-effort) to
  `AUDIT.MCP_QUERY_LOG`; the managed server logs through Snowflake's query
  history.
- Object-level grants for `CLAIMS_MCP_READER` are applied in
  `snowflake/setup/011` (see below).

---

## 5. Setup steps

1. **Roles / warehouses / schemas** — run the bootstrap scripts in order:
   `snowflake/setup/001`–`004` (roles incl. `CLAIMS_MCP_READER`, warehouses incl.
   `WH_CLAIMS_MCP`, the 9-schema topology incl. `SEMANTIC`/`CORTEX`/`AUDIT`).
2. **Cortex + MCP objects** — run the platform's Cortex/MCP setup scripts:
   - `snowflake/setup/009` — Cortex Search services + semantic model registration.
   - `snowflake/setup/010` — Cortex Agent objects.
   - `snowflake/setup/011` — the `CLAIMS_MCP_READER` read-only grant surface and
     the Snowflake-managed MCP server definition.
3. **Detailed walkthrough** — follow **`docs/cortex_mcp_setup.md`** for the
   end-to-end managed-MCP enablement, semantic-model stage path, and endpoint URL.
4. **Point a client at it** — use the example configs in
   [`clients/`](clients/) (§ below).

> If your account does not yet have the managed MCP server / Cortex enabled, use
> the **fallback** server (§6) while you enable it.

---

## 6. Local client examples

Ready-to-edit configs live in [`clients/`](clients/). Each has a **PRIMARY**
managed-MCP block and a clearly-commented **FALLBACK** local-stdio block; fill the
`<PLACEHOLDERS>` and use `CLAIMS_MCP_READER` / `WH_CLAIMS_MCP`.

- **Claude Desktop** — [`clients/claude_desktop_config.example.json`](clients/claude_desktop_config.example.json)
  (`mcpServers`; remote managed endpoint via `mcp-remote`, plus a commented local
  stdio fallback).
- **Cursor** — [`clients/cursor_mcp_config.example.json`](clients/cursor_mcp_config.example.json)
  (`.cursor/mcp.json` style; native remote URL transport).
- **VS Code** — [`clients/vscode_mcp_config.example.json`](clients/vscode_mcp_config.example.json)
  (`.vscode/mcp.json`; `inputs` prompt for secrets so tokens are never committed).

---

## 7. ChatGPT limitations

ChatGPT does not spawn arbitrary local MCP processes the way a desktop IDE does;
its supported path is the **remote connector / custom-app** mechanism pointed at
the **Snowflake-managed** endpoint. See full guidance in
[`clients/chatgpt_remote_mcp_notes.md`](clients/chatgpt_remote_mcp_notes.md).

> **Use this with ChatGPT only through the MCP/custom app/connector mechanism
> available to your ChatGPT plan and workspace. If local custom MCP is not
> available in your ChatGPT environment, use an MCP-compatible host such as Claude
> Desktop, Cursor, or VS Code, or expose a remote MCP server through the supported
> ChatGPT app/connector path.**

**Never** expose the local credential-bearing fallback server through a public
tunnel to reach ChatGPT — use the managed endpoint, which Snowflake authenticates
and governs.

---

## 8. Fallback custom server — when to use

Use [`fallback_custom_server/`](fallback_custom_server/) **only** when the
Snowflake-managed MCP server is unavailable in your account (Cortex/managed-MCP
not yet enabled, an air-gapped dev box, or while you wait on enablement). It uses
the official MCP Python SDK + the Snowflake Python connector and exposes a small
set of **read-only** tools with the same guardrails: `SELECT`-only, schema
allowlist, row limits, denied keywords, and logging to `AUDIT.MCP_QUERY_LOG`. It
is a **fallback path, not the primary recommendation.** See its
[`README.md`](fallback_custom_server/README.md).

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Authentication failed` / 401 | Expired/invalid PAT or OAuth token; wrong user | Mint a fresh short-lived token for the `CLAIMS_MCP_READER` user; check key-pair path for the fallback server. |
| `Insufficient privileges` on a view | Object grant to `CLAIMS_MCP_READER` missing | Re-run `snowflake/setup/011`; confirm the view is in the approved `GOLD`/`SEMANTIC`/selected `SILVER_DIMENSIONAL`/`AUDIT`-summary allowlist. |
| `Role 'CLAIMS_MCP_READER' does not exist` | Bootstrap not run | Run `snowflake/setup/001`–`003`. |
| `Cortex Analyst not enabled` / function not found | Cortex not enabled or not entitled in the account/region | Enable Cortex per `docs/cortex_mcp_setup.md`; confirm region support; otherwise use approved SQL tools meanwhile. |
| Client shows no tools / cannot connect | Wrong MCP endpoint URL or transport; managed server not deployed | Verify the endpoint URL from `snowflake/setup/011` / `docs/cortex_mcp_setup.md`; check transport (HTTP/SSE vs stdio). |
| Query rejected by guardrail (fallback) | Non-SELECT, denied keyword, or out-of-allowlist schema | Rewrite as a single `SELECT`/`WITH` over an allowed schema; the server injects a `LIMIT`. |
| Need to audit what the LLM ran | — | Inspect `AUDIT.MCP_QUERY_LOG` (fallback server) and Snowflake **Query History** filtered to `WH_CLAIMS_MCP` / `CLAIMS_MCP_READER` (managed server). |

---

## Directory map

```
mcp/
├── README.md                                  ← you are here
├── clients/
│   ├── claude_desktop_config.example.json
│   ├── cursor_mcp_config.example.json
│   ├── vscode_mcp_config.example.json
│   └── chatgpt_remote_mcp_notes.md
└── fallback_custom_server/                    ← FALLBACK ONLY
    ├── README.md
    ├── pyproject.toml
    ├── server.py
    └── tools/
        ├── snowflake_connection.py
        ├── safe_sql.py
        ├── semantic_catalog.py
        └── cortex_analyst_client.py
```
