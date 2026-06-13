# Incremental Strategy

How the platform processes only new/changed data while remaining correct under late arrivals, duplicates, adjustments, voids, and reversals. All SQL runs in Snowflake (dbt on `WH_CLAIMS_TRANSFORM`); orchestration, if scheduled, is via Snowflake Tasks. No external orchestrator.

> ⚠️ **Synthetic data.** Not real CMS/Medicare/Medicaid/PHI.

---

## 1. Three timestamps — and why they differ

| Timestamp | Meaning | Used for |
|---|---|---|
| `business_event_ts` | When the claim event actually happened (e.g., service or adjudication event). | **Primary watermark** + period attribution. |
| `source_extract_ts` | When the source system produced the extract file. | Tie-breaking / extract lineage. |
| `ingest_ts` | When Snowflake loaded the row (`COPY INTO`). | Operational lag, late-arrival detection. |

A claim can have an **old** `business_event_ts` but a **recent** `ingest_ts` — that is a **late arrival**. We must attribute it to the original business period, not the load date. Using `ingest_ts` as the watermark would silently lose late claims; using `business_event_ts` + a lookback window catches them.

---

## 2. Watermarks + lookback window

Each model stores its `last_successful_watermark` (max processed `business_event_ts`) and a `lookback_days` in `CONTROL.WATERMARKS`. Incremental runs select:

```sql
-- Conceptual incremental filter (dbt macro get_incremental_filter)
WHERE business_event_ts >= (
    SELECT last_successful_watermark - (lookback_days || ' days')::INTERVAL
    FROM CONTROL.WATERMARKS
    WHERE model_name = 'SILVER_CANONICAL.CLAIM_HEADER'
)
```

The lookback (e.g., 14–30 days for claims) re-scans a trailing window each run so late-arriving rows are reprocessed and corrected. The window is bounded, so cost stays predictable. On success, the watermark advances to the new max `business_event_ts`.

In dbt:

```sql
{{ config(materialized='incremental', unique_key='idempotency_key', incremental_strategy='merge') }}

SELECT ...
FROM {{ ref('br_claim_header') }}
{% if is_incremental() %}
WHERE business_event_ts >= {{ incremental_floor('silver_canonical.claim_header') }}
{% endif %}
```

---

## 3. Late arrivals

Because the filter is keyed on `business_event_ts` with a trailing lookback, a row that lands today (`ingest_ts = today`) but happened 10 days ago (`business_event_ts = today-10`) is **inside** the window and gets processed. It is attributed to its true period in the facts, and surfaced in `GOLD.LATE_ARRIVALS` for monitoring:

```sql
SELECT
    DATE_TRUNC('month', business_event_ts)            AS business_month,
    DATEDIFF('day', business_event_ts, ingest_ts)     AS arrival_lag_days,
    COUNT(*)                                           AS late_claim_count
FROM SILVER_CANONICAL.CLAIM_HEADER
WHERE DATEDIFF('day', business_event_ts, ingest_ts) > 1
GROUP BY 1, 2;
```

If a claim arrives **after** the lookback window has passed, it is handled by a **reprocessing** request (see §6), not silently dropped.

---

## 4. Dedupe (natural_key + payload_hash + event ts)

Sources can resend the same record. We keep exactly one current-state row per natural key, choosing the latest business event, with `payload_hash` to detect true changes:

```sql
-- Keep the latest version per claim; collapse exact duplicates.
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY natural_key
            ORDER BY business_event_ts DESC, source_extract_ts DESC, ingest_ts DESC
        ) AS rn
    FROM source_rows
)
SELECT * FROM ranked
QUALIFY rn = 1;
```

- `natural_key` defines identity (e.g., `claim_id`).
- `payload_hash` (hash of business fields) lets us tell a real change from a redundant resend; identical hashes are no-ops in the MERGE.
- The losing rows can be routed to `CONTROL.QUARANTINE` with reason `dedupe_loser` when auditability of dropped duplicates is required.

The `idempotency_key = natural_key || '|' || payload_hash || '|' || business_event_ts` is the MERGE `unique_key`.

---

## 5. Idempotency via MERGE

Upserts are idempotent: re-running the same window produces the same target.

```sql
MERGE INTO SILVER_CANONICAL.CLAIM_HEADER tgt
USING (
    SELECT * FROM staged_deduped   -- output of §4
) src
ON tgt.idempotency_key = src.idempotency_key
WHEN MATCHED AND tgt.payload_hash <> src.payload_hash THEN UPDATE SET
    tgt.claim_status   = src.claim_status,
    tgt.total_paid_amt = src.total_paid_amt,
    tgt.payload_hash   = src.payload_hash,
    tgt.business_event_ts = src.business_event_ts,
    tgt.ingest_ts      = src.ingest_ts
WHEN NOT MATCHED THEN INSERT (...) VALUES (...);
```

Running it twice changes nothing the second time (same `idempotency_key`, same `payload_hash` -> NOOP). The merge action (INSERT/UPDATE/NOOP) is recorded in `CONTROL.IDEMPOTENCY_KEYS`.

---

## 6. Reprocessing / backfill

For corrections beyond the lookback window (schema fix, DQ defect, very-late claims), file a `CONTROL.REPROCESS_REQUESTS` row with a bounded `from_ts`/`to_ts`:

```sql
-- Rebuild a window deterministically from immutable BRONZE.
INSERT INTO CONTROL.REPROCESS_REQUESTS
    (reprocess_id, target_model, from_ts, to_ts, reason, reprocess_status)
VALUES
    (UUID_STRING(), 'SILVER_CANONICAL.CLAIM_HEADER',
     '2026-01-01', '2026-01-31', 'late_claims_beyond_lookback', 'REQUESTED');
```

The reprocess macro filters BRONZE to `[from_ts, to_ts]`, re-runs dedupe + MERGE for that window only, and — because of idempotency — converges to the correct current state without double counting. Watermarks are **not** moved backward; reprocessing is window-scoped.

---

## 7. Voids, reversals, and adjustment chains

Claims have a lifecycle. We model it explicitly so current-state facts net correctly:

- **Void** (`is_void = TRUE`): the claim is cancelled. It contributes **zero** to paid/charge in current-state facts but remains in BRONZE.
- **Reversal** (`is_reversal = TRUE`): a negating entry that offsets a prior claim (paid amounts net to zero).
- **Adjustment chain** (`adjustment_of_claim_id`): a corrected claim supersedes the original; the **latest** node in the chain is current state.

```sql
-- Resolve the adjustment chain: keep the latest node per logical claim,
-- and net out voids/reversals.
WITH chain AS (
    SELECT
        COALESCE(adjustment_of_claim_id, claim_id) AS logical_claim_id,
        claim_id,
        is_void,
        is_reversal,
        total_paid_amt,
        business_event_ts,
        ROW_NUMBER() OVER (
            PARTITION BY COALESCE(adjustment_of_claim_id, claim_id)
            ORDER BY business_event_ts DESC, ingest_ts DESC
        ) AS rn
    FROM SILVER_CANONICAL.CLAIM_HEADER
)
SELECT
    logical_claim_id,
    CASE WHEN is_void OR is_reversal THEN 0 ELSE total_paid_amt END AS effective_paid_amt
FROM chain
WHERE rn = 1;   -- latest node wins
```

Reconciliation tests assert that:
- adjustment chains resolve to a single current node,
- voids/reversals net to zero against their originals,
- `SUM(line.paid) = header.paid` for the surviving node.

---

## 8. Summary

| Concern | Mechanism |
|---|---|
| Process only new data | Watermark on `business_event_ts`. |
| Catch late arrivals | Trailing `lookback_days` window. |
| Remove duplicates | `QUALIFY ROW_NUMBER()` on `natural_key` + event ts. |
| Detect real change | `payload_hash`. |
| Safe re-runs | `idempotency_key` + `MERGE`. |
| Corrections | `CONTROL.REPROCESS_REQUESTS` window rebuild. |
| Lifecycle | Explicit void/reversal/adjustment resolution. |

All of this is enforced through the DCM (`CONTROL.*`/`AUDIT.*`); see [`data_control_model.md`](data_control_model.md).
