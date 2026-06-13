# Demo Script (for interviews)

A ready-to-run narrative for demoing **snowflake-claims-platform** in an interview. Two timings (10 and 30 minutes), system-design talking points, production tradeoffs, and how to be precise about synthetic vs real claims.

> ⚠️ **Always open with the disclaimer:** "This is **100% synthetic, machine-generated** data. It is **not** real CMS/Medicare/Medicaid/CMS RIF/TAF data and contains **no PHI**. I built the schema to *look like* claims so the engineering is realistic, but every value is fabricated."

---

## The one-sentence pitch

"A 100% Snowflake-only claims analytics platform — internal-stage ingestion, a medallion model, a formal Data Control Model for production reliability, a certified semantic layer, and AI access through Snowflake-managed MCP — with **no external cloud storage or orchestration at all**."

---

## 10-minute demo

1. **(0:00) Framing + disclaimer (1 min).** State the synthetic-data disclaimer. Then: "Single vendor, Snowflake only — no S3/Airflow/Databricks. Ingestion is internal stage + PUT + COPY INTO."
2. **(1:00) Architecture (1.5 min).** Show the README Mermaid diagram. Walk RAW -> BRONZE (VARIANT) -> SILVER_CANONICAL -> SILVER_DIMENSIONAL -> GOLD -> SEMANTIC/CORTEX -> MCP, with CONTROL + AUDIT cross-cutting.
3. **(2:30) Ingestion (1.5 min).** Show `make stage-load`: `PUT` to `@RAW.CLAIMS_INTERNAL_STAGE`, then `COPY INTO RAW`. Emphasize *internal* stage and that COPY rejects go to `CONTROL.QUARANTINE`.
4. **(4:00) The DCM (2 min).** Open `docs/data_control_model.md` and show the use-case matrix. Pick three rows live: **incremental load** (watermark + lookback), **idempotent load** (QUALIFY + MERGE), **quarantine**. "This is what makes it production, not a demo."
5. **(6:00) A late arrival (1.5 min).** Show `GOLD.LATE_ARRIVALS` and explain `business_event_ts` vs `ingest_ts` and the lookback window catching late claims into the right period.
6. **(7:30) Cortex/MCP (2 min).** Run two validation prompts via an MCP client: "total paid by month" and "define PMPM by plan type". Note it's read-only via `CLAIMS_MCP_READER` and every query is audited.
7. **(9:30) Close (0.5 min).** "Everything stayed inside Snowflake; the DCM gives me reliability, the semantic layer gives me consistency, MCP gives me governed AI access."

---

## 30-minute demo

Use the 10-minute flow as the spine, then go deep:

1. **Data model (5 min).** `docs/data_model.md`: header vs line grain, the `SUM(line.paid) = header.paid` invariant, the star-schema ERD, and member-months as the PMPM denominator.
2. **Incremental strategy (6 min).** `docs/incremental_strategy.md`: walk the three timestamps, the lookback SQL, dedupe via `QUALIFY ROW_NUMBER()` on `natural_key + payload_hash + event ts`, and the idempotent `MERGE`. Then show **adjustment chains / voids / reversals** resolving to current state.
3. **DCM end-to-end (6 min).** Walk all ten domains A–J and the lifecycle sequence diagram. Show `CONTROL.WATERMARKS`, `CONTROL.QUARANTINE`, `AUDIT.RUN_LOG`, `AUDIT.LINEAGE_EDGES`. Demonstrate a reprocessing window.
4. **CI/CD (4 min).** `docs/ci_cd.md`: isolated `DBT_CI_PR_<n>` schema, `dbt build --select state:modified+` with full-build fallback, manifest artifacts, key-pair auth.
5. **Semantic + Cortex + MCP (5 min).** Show the semantic model YAML, run several validation prompts including "why did March paid change" and "grain of fact_claim_line" and "quarantined records and why".
6. **Workbooks (2 min).** Flip through PMPM, denial rate, and the quarantine dashboard.
7. **Q&A / tradeoffs (2 min).** Field design questions using the talking points below.

---

## System-design talking points

- **Why medallion + VARIANT bronze?** Append-only VARIANT preserves raw truth so we can always replay/reprocess; typing and dedupe happen in canonical, modeling in dimensional, certification in gold.
- **Why a separate DCM instead of ad-hoc logic?** It turns reliability into a first-class, queryable contract: watermarks, idempotency, quarantine, lineage, freshness, certification. Operability is designed-in, not bolted-on.
- **Why `business_event_ts` as the watermark (not `ingest_ts`)?** Correct period attribution and late-arrival handling. `ingest_ts` would silently lose or misattribute late claims.
- **Why warehouse-per-workload?** Cost isolation and concurrency control (load vs transform vs analyst vs CI vs MCP).
- **Why Snowflake-managed MCP + read-only role?** AI access inherits Snowflake RBAC; clients can't mutate data and every query is audited.
- **Why single-vendor?** Eliminates external bucket exposure and cross-system orchestration complexity; everything is governed by one RBAC and one audit surface. Tradeoff: some streaming/3rd-party patterns are intentionally out of scope.

---

## Production tradeoffs (be honest)

- **Lookback window size** trades cost vs late-arrival completeness; beyond the window you rely on explicit reprocessing.
- **Dynamic Tables vs dbt:** Dynamic Tables reduce orchestration code but give less control over DCM watermark/quarantine semantics; dbt is the default here, Tasks schedule it.
- **Quarantine vs fail-fast:** quarantining keeps the pipeline moving but requires disciplined replay so quarantine doesn't silently grow.
- **Certification overhead:** certifying metrics adds process but prevents metric drift across Cortex and Workbooks.
- **Single-vendor lock-in** is a deliberate constraint here; in a real org you'd weigh portability.

---

## How to explain synthetic vs real claims

- Be unambiguous: "**Synthetic. Not real. No PHI.** The generator fabricates members, NPIs, codes, and dollars with plausible distributions."
- Explain *why it still demonstrates skill*: "The hard parts — grain, incrementality, late arrivals, adjustments, reconciliation, governance — are identical whether the data is real or synthetic. Synthetic data lets me exercise all of them safely and shareably."
- If asked about real CMS data: "I deliberately did **not** use real RIF/TAF/PHI. Wiring real data would mean adding PHI controls (masking, row-access policies, BAA, de-identification) — which the RBAC and `CLAIMS_SECURITY_ADMIN` structure here is already designed to support."
- Never overclaim: do not call it Medicare/Medicaid data, and do not imply real-world denial rates or costs.
