# ChatGPT + Snowflake MCP — precise integration notes

> **Synthetic data.** Everything served through this MCP layer is machine-generated
> synthetic claims data. There is **no real PHI/PII**.

This document explains how (and whether) you can use the snowflake-claims-platform
MCP layer from ChatGPT, what the transport options are, and the security rules you
must follow.

---

## 1. Local stdio MCP vs. remote HTTP/SSE MCP

MCP servers are reachable over two transports. The distinction matters a lot for
ChatGPT.

| | **Local stdio MCP** | **Remote HTTP/SSE MCP** |
|---|---|---|
| How the host talks to it | Spawns a local process and talks over stdin/stdout | Connects to a URL over HTTPS (Streamable HTTP / SSE) |
| Where it runs | On your laptop, next to the host app | On a server / in Snowflake's managed service |
| Credentials | Live in the local process env | Presented per-request as a Bearer/OAuth token |
| Typical hosts | Claude Desktop, Cursor, VS Code | ChatGPT connectors/apps, Claude Desktop (via `mcp-remote`), Cursor, VS Code |
| Our usage | The **fallback** custom server (`mcp/fallback_custom_server`) | The **primary** Snowflake-managed MCP endpoint |

ChatGPT does **not** spawn arbitrary local processes the way a desktop IDE does.
Its supported path for MCP is the **remote HTTP/SSE connector/app** mechanism. So
to reach this platform from ChatGPT you use the **remote, Snowflake-managed MCP
endpoint** — not the local stdio fallback server.

---

## 2. The exact ChatGPT availability disclaimer

> **Use this with ChatGPT only through the MCP/custom app/connector mechanism
> available to your ChatGPT plan and workspace. If local custom MCP is not
> available in your ChatGPT environment, use an MCP-compatible host such as Claude
> Desktop, Cursor, or VS Code, or expose a remote MCP server through the supported
> ChatGPT app/connector path.**

MCP/connector/custom-app availability varies by ChatGPT plan, workspace admin
settings, and region. Do **not** assume every ChatGPT install can attach an
arbitrary MCP server. Confirm the capability exists in *your* workspace before
relying on it.

---

## 3. Exposing the Snowflake-managed MCP server to ChatGPT

When the connector/app path is available in your ChatGPT workspace:

1. **Confirm the managed MCP endpoint exists.** It is created by the platform
   setup scripts (`snowflake/setup/009`–`011`) and documented in
   `docs/cortex_mcp_setup.md`. The URL looks like:

   ```
   https://<ORG>-<ACCOUNT>.snowflakecomputing.com/api/v2/databases/CLAIMS_DEV/schemas/CORTEX/mcp-servers/CLAIMS_MCP
   ```

2. **Register it as a connector / custom app** in ChatGPT using the remote MCP
   URL above. Use the transport ChatGPT expects (Streamable HTTP / SSE).

3. **Authenticate as `CLAIMS_MCP_READER`.** Provide a short-lived Snowflake
   Programmatic Access Token (PAT) or an OAuth bearer token for a user whose
   `DEFAULT_ROLE` is `CLAIMS_MCP_READER`. The token rides in the `Authorization:
   Bearer …` header. The endpoint runs on warehouse `WH_CLAIMS_MCP`.

4. **Tools exposed.** Through the managed endpoint ChatGPT sees Cortex Analyst
   (governed NL-to-SQL over the claims semantic model), Cortex Search (doc/lookup
   retrieval), Cortex Agents (orchestration), and the approved read-only SQL
   surface over `GOLD` / `SEMANTIC` / selected `SILVER_DIMENSIONAL`.

If the connector/app path is **not** available to you, fall back to an
MCP-compatible host (Claude Desktop, Cursor, VS Code) per the disclaimer above —
do not try to make ChatGPT spawn the local stdio server, it cannot.

---

## 4. SECURITY WARNING — never expose a local credentialed MCP server publicly

The fallback server in `mcp/fallback_custom_server` holds **live Snowflake
credentials** in its process environment. It is designed for **local stdio use
only**.

- **Do NOT** put the local fallback server behind a public URL / tunnel
  (ngrok, cloudflared, reverse proxy, a cloud VM with an open port) so ChatGPT
  can reach it. That turns a laptop-local, credential-bearing process into a
  public, unauthenticated SQL gateway into Snowflake.
- A public remote MCP endpoint **must** be the Snowflake-managed one, where
  Snowflake performs token authentication, RBAC enforcement, and request
  governance — not a hand-rolled tunnel in front of your local server.
- If you genuinely need a self-hosted remote MCP server, it must enforce its own
  authentication, TLS, network allowlisting, and per-request authorization before
  it ever touches the Snowflake connector. That is out of scope for this
  reference platform; the managed endpoint already does all of this.

---

## 5. Recommended dev setup (least privilege + short-lived auth)

- **Role:** always `CLAIMS_MCP_READER`. It can `SELECT` only from approved
  `GOLD`, `SEMANTIC`, selected `SILVER_DIMENSIONAL`, and selected `AUDIT` summary
  views. It cannot read `RAW`/`BRONZE`/`CONTROL` internals or full quarantine
  payloads, and it cannot write or run DDL/DML.
- **Warehouse:** `WH_CLAIMS_MCP` (XSMALL, aggressively auto-suspended).
- **Auth:** prefer **short-lived** tokens — a PAT with a short expiry or an OAuth
  access token. Rotate them; never paste a long-lived secret into a connector
  config. For the local fallback server, prefer **key-pair** auth over passwords.
- **Database:** `CLAIMS_DEV` for development; `CLAIMS_PROD` only with the prod
  reader user and prod approvals.
- **Verify scope** by asking the model to list available semantic objects first;
  the surface should be limited to the approved governed views and metrics.
