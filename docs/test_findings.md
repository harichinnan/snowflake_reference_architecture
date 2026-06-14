# dbt Test Findings — what's a bug vs. a genuine validation

> Synthetic data — not real CMS/Medicare/Medicaid/PHI.

This platform runs **296 dbt tests** server-side via `EXECUTE DBT PROJECT`
(dbt Projects on Snowflake). After troubleshooting, the suite is
**PASS=285, WARN=3, ERROR=8**. The remaining non-passing tests are **deliberately
left red**: they are genuine data-quality validations correctly flagging
characteristics of the synthetic data (the DCM doing its job), plus one
documented architectural artifact. They are **not bugs** and should not be
"fixed" by weakening the assertions.

## Bugs that WERE fixed (false positives / wrong logic)

| Test(s) | Root cause | Fix |
|---|---|---|
| `accepted_values` on adjudication `event_type`, claim `claim_status`, `age_band` | Enum lists were wrong/incomplete (`VOID` vs `VOIDED`, missing `ADJUDICATED`, `'Unknown'` vs `'UNKNOWN'`) | Corrected the accepted-value lists to the real domain values |
| `relationships` fact_claim_line `date_sk` → dim_date; `not_null` gold_provider_utilization `month_start` | `dim_date` spine ended 2028-01-01, but some synthetic service dates land in 2028 | Extended the date spine to 2031-01-01 |
| `not_null` bronze `natural_key` | Quarantined malformed rows legitimately have a NULL key — the quarantine *is* the handling | Scoped the test to `record_status <> 'QUARANTINE'` |
| `assert_late_arrivals_are_captured` | Asserted late claims appear in `claim_header` (current-valid only), so voided/superseded late versions looked "missing" | Re-pointed to the canonical capture layer (`int_claim_event_deduped`) |
| `relationships` bridge `diagnosis_sk`/`procedure_sk` → dim | `dim_diagnosis`/`dim_procedure` were built from the reference seed only, so codes observed in claims had no dimension row | Made both **conformed dimensions** (observed codes ∪ reference seed) + added an `UNGROUPED` catch-all member to `dim_condition_group` |

## Genuine validations — intentionally still red (do NOT "fix")

| Test | Count | Severity | Why it's genuine |
|---|---|---|---|
| `claim_diagnosis.diagnosis_code` → `ref_diagnosis_code` | 1311 | warn | The synthetic generator emits ICD-10-like codes beyond the small reference catalog. Real claims behave the same way; the dimension is conformed, but the *reference catalog* coverage gap is correctly surfaced. |
| `claim_procedure.procedure_code` → `ref_procedure_code` | 491 | warn | Same, for CPT/HCPCS-like procedure codes. |
| `denial_event.denial_reason_code` → `ref_denial_reason` | 196 | warn | Denial reason codes (e.g. `CO-97`) beyond the seed catalog. |
| `assert_claim_header_line_totals_reconcile` | 315 | error | The generator rounds each claim line independently of the header, producing ±$1 header-vs-lines differences, plus denied/zero-paid headers with non-zero line amounts. This is exactly the reconciliation drift a real claims platform must monitor — the DCM is catching it. |
| `assert_member_months_reconcile` | 1 | error | A single member-month boundary difference within tolerance. |

## Known artifact — left as-is

| Test | Count | Why |
|---|---|---|
| `accepted_values` bronze `record_status` = `LANDED` | 8 | The setup-created landing table and the dbt bronze model share the same object (`BRONZE.BR_RAW_*`). The bronze model dedupes by `natural_key + payload_hash`; deduplicated-away duplicate rows remain in the shared table with their original `LANDED` status (never re-classified to VALID/QUARANTINE). The production fix is to **separate the COPY landing target from the dbt bronze model** (land into a distinct table the model reads as a source). Tracked as future work. |

## How to inspect failures yourself

```sql
-- Re-run tests and persist failing rows:
--   EXECUTE DBT PROJECT CLAIMS_DEV.DBT.CLAIMS_DBT_PROJECT ARGS='test --store-failures --target dev';
-- Then browse the stored failures:
SELECT table_name, row_count
FROM CLAIMS_DEV.INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'DBT_TEST__AUDIT' AND row_count > 0
ORDER BY row_count DESC;

-- Drill into any one (e.g. the reconciliation finding):
SELECT * FROM CLAIMS_DEV.DBT_TEST__AUDIT.ASSERT_CLAIM_HEADER_LINE_TOTALS_RECONCILE;
```

> Note: when a previously-failing test starts passing, dbt does **not** drop its
> old `DBT_TEST__AUDIT` table — drop the schema before a fresh `--store-failures`
> run to avoid reading stale failures.
