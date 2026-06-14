# Operational Runbook

Diagnose and resolve common operational issues. The DCM (`CONTROL.*`/`AUDIT.*`) is your primary instrument — most answers are a query away. Everything runs inside Snowflake, so the DCM tables are where you look first.

> ⚠️ **Synthetic data.** Not real CMS/Medicare/Medicaid/PHI.

---

## Quick triage

```sql
-- Recent runs and outcomes
SELECT * FROM AUDIT.RUN_LOG ORDER BY started_ts DESC LIMIT 20;
-- Batches
SELECT * FROM CONTROL.BATCH_REGISTRY ORDER BY batch_started_ts DESC LIMIT 20;
-- Freshness
SELECT * FROM CONTROL.SLA_FRESHNESS WHERE sla_status = 'BREACH';
-- Quarantine
SELECT model_name, reject_reason, COUNT(*) FROM CONTROL.QUARANTINE
WHERE NOT is_resolved GROUP BY 1,2 ORDER BY 3 DESC;
```

---

## 1. Failed loads (PUT / COPY INTO)

**Symptoms:** `CONTROL.BATCH_REGISTRY.batch_status = FAILED`; `rows_rejected > 0`.

**Diagnose:**
```sql
SELECT * FROM CONTROL.BATCH_REGISTRY WHERE batch_status = 'FAILED' ORDER BY batch_started_ts DESC;
-- COPY-level rejects
SELECT * FROM TABLE(VALIDATE(RAW.RAW_CLAIM_HEADER, JOB_ID => '_last'));
SELECT * FROM CONTROL.QUARANTINE WHERE batch_id = '<batch_id>';
```

**Resolve:**
- File/format issue: confirm the NDJSON file format `RAW.FF_NDJSON` and the internal stage path; re-`PUT` with `OVERWRITE=TRUE`.
- Partial load: `COPY INTO ... ON_ERROR='CONTINUE'` already loaded good rows and quarantined the rest; fix bad rows and replay from quarantine.
- Never reach for external storage — staging is internal-only. Re-run `make stage-load ENV=...`.

---

## 2. Stale watermark

**Symptoms:** `CONTROL.SLA_FRESHNESS.sla_status = BREACH`; newest `business_event_ts` not advancing.

**Diagnose:**
```sql
SELECT * FROM CONTROL.WATERMARKS WHERE model_name = '<model>';
SELECT MAX(business_event_ts) FROM SILVER_CANONICAL.CLAIM_HEADER;
```

**Resolve:**
- If upstream simply had no new data, this is expected — confirm via `BATCH_REGISTRY`.
- If a run failed mid-way, the watermark should **not** have advanced (it only moves on success). Re-run dbt; idempotency makes this safe.
- If a watermark advanced incorrectly (rare), correct it and reprocess the affected window via `CONTROL.REPROCESS_REQUESTS` (see §5 in [`incremental_strategy.md`](incremental_strategy.md)).

---

## 3. Duplicate batch

**Symptoms:** same file/batch loaded twice; concern about double counting.

**Diagnose:**
```sql
SELECT batch_id, source_file_name, COUNT(*) FROM CONTROL.BATCH_REGISTRY
GROUP BY 1,2 HAVING COUNT(*) > 1;
SELECT idempotency_key, COUNT(*) FROM CONTROL.IDEMPOTENCY_KEYS GROUP BY 1 HAVING COUNT(*)>1;
```

**Resolve:**
- **No data damage:** dedupe (`QUALIFY ROW_NUMBER()`) + `MERGE` on `idempotency_key` means a re-loaded batch is a no-op in current-state tables. Verify counts in `FACT_CLAIM_HEADER` are unchanged.
- Mark the redundant batch as superseded in `BATCH_REGISTRY` for clarity.

---

## 4. Quarantine growth

**Symptoms:** `CONTROL.QUARANTINE` rows trending up; `quarantine_growth_within_threshold` test failing.

**Diagnose:**
```sql
SELECT reject_reason, COUNT(*) FROM CONTROL.QUARANTINE
WHERE NOT is_resolved GROUP BY 1 ORDER BY 2 DESC;
SELECT raw_payload FROM CONTROL.QUARANTINE WHERE reject_reason = '<reason>' LIMIT 10;
```

**Resolve:**
- Root-cause by `reject_reason` (schema drift, null keys, negative paid, dedupe losers).
- Fix the generator/source or the model logic; then **replay** quarantined rows back through the model and set `is_resolved = TRUE`.
- If the spike is a source defect, open a `REPROCESS_REQUESTS` window after the fix.

---

## 5. Failed reconciliation (header != sum of lines)

**Symptoms:** test `header_equals_sum_of_lines` fails; `AUDIT.DQ_RESULTS` shows failures.

**Diagnose:**
```sql
SELECT h.claim_id, h.total_paid_amt, SUM(l.line_paid_amt) AS line_sum
FROM SILVER_DIMENSIONAL.FACT_CLAIM_HEADER h
JOIN SILVER_DIMENSIONAL.FACT_CLAIM_LINE l ON l.claim_sk = h.claim_sk
GROUP BY 1,2 HAVING h.total_paid_amt <> SUM(l.line_paid_amt);
```

**Resolve:**
- Missing lines: check whether line records were quarantined or arrived late (lookback window).
- Adjustment chain: ensure you are comparing the **surviving** node, not a superseded version (see void/reversal/adjustment resolution).
- Reprocess the affected claims' window once lines are present.

---

## 6. Broken semantic metric

**Symptoms:** Cortex Analyst / Workbook returns a wrong or undefined metric (e.g., PMPM off).

**Diagnose:**
```sql
SELECT * FROM CONTROL.SEMANTIC_CERTIFICATION WHERE metric_name = 'pmpm';
```

**Resolve:**
- Confirm the metric is `CERTIFIED` and its `definition_sql` matches the semantic model YAML.
- PMPM denominator: validate `GOLD.MEMBER_MONTHS` (non-overlap test). A bad denominator is the usual culprit.
- Update the semantic model, re-certify, and re-register with Cortex/MCP. Only certified metrics are exposed.

---

## 7. MCP access failure

**Symptoms:** MCP client cannot connect, or returns permission errors.

**Diagnose:**
```sql
SHOW GRANTS TO ROLE CLAIMS_MCP_READER;
SELECT * FROM AUDIT.ACCESS_AUDIT ORDER BY query_ts DESC LIMIT 20;
```

**Resolve:**
- Auth: verify key-pair (`snowflake_jwt`) and that the client uses role `CLAIMS_MCP_READER` + warehouse `WH_CLAIMS_MCP`.
- Grants: ensure `USAGE` on `SEMANTIC`/`GOLD`/`CORTEX` and `SELECT` on the certified views; the role is **read-only** by design (write attempts will fail — that is correct).
- Managed vs fallback: prefer the **Snowflake-managed MCP server**; the Snowflake-Labs MCP is a **deprecated fallback** only.
- ChatGPT: connectivity depends on plan/workspace connector support — see the disclaimer in [`cortex_mcp_setup.md`](cortex_mcp_setup.md). If unavailable, use Claude Desktop / Cursor / VS Code.

---

## Escalation

If a control table itself looks inconsistent, freeze loads (pause the Snowflake Task), snapshot `CONTROL.*`/`AUDIT.*`, and rebuild affected models from immutable `BRONZE` via a `REPROCESS_REQUESTS` window. Because BRONZE is append-only and loads are idempotent, you can always reconstruct current state.
