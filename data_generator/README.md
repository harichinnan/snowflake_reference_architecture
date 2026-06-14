# Synthetic Healthcare Claims Data Generator

> ## ⚠️ 100% SYNTHETIC DATA — NOT REAL HEALTHCARE DATA
>
> Every identifier, member, provider, NPI, claim, diagnosis, drug, and dollar
> amount produced by this tool is **randomly fabricated**.
>
> This is **NOT** Medicare, **NOT** Medicaid, **NOT** CMS RIF, **NOT** CMS TAF,
> and contains **NO** Protected Health Information (PHI) or PII of any real
> person, provider, or payer. NPIs are synthetic 10-digit strings that
> deliberately begin with `9` and skip the real Luhn check digit, so they
> **cannot** collide with valid NPPES registry numbers. Any resemblance to a
> real entity or claim is purely coincidental.
>
> **Use only for engineering, testing, demos, and pipeline development.**

A deterministic, seed-driven generator for the **snowflake-claims-platform**.
It writes newline-delimited JSON (NDJSON) event files that model a real claims
ingestion landing zone, then those files are `PUT` to Snowflake **internal
stages** and `COPY INTO` bronze (raw) tables. The generator writes **local**
files that are then loaded into Snowflake.

---

## What it generates

Each output line is one self-describing **event** with a bronze-style
**envelope** wrapping a nested **payload**:

```jsonc
{
  "source_system":      "SYNTH_CLAIMS_GEN",
  "source_file_name":   "claims_20251108.ndjson",
  "source_extract_ts":  "2025-11-09T13:30:06+00:00",
  "file_generation_ts": "2026-06-13T08:00:00+00:00",   // fixed via --as-of, not wall-clock
  "event_type":         "CLAIM",
  "business_event_ts":  "2025-11-08T08:04:27+00:00",
  "natural_key":        { "claim_id": "CLM86430098180", "claim_version": 1 },
  "payload_hash":       "995283d5…",                    // sha256(canonical_json(payload))
  "payload":            { /* event-specific nested object, see below */ }
}
```

`payload_hash` is the SHA-256 of the **canonical** JSON of the payload
(`sort_keys=True`, compact separators). It mirrors how the bronze layer is
expected to compute a stable hash for de-duplication and change detection.

### Event types and payloads

| Event         | File                          | Payload highlights |
|---------------|-------------------------------|--------------------|
| `CLAIM`       | `claim_events.ndjson`         | claim header + `diagnoses[]`, `procedures[]`, `lines[]`, adjustment/void/reversal lineage |
| `ELIGIBILITY` | `eligibility_events.ndjson`   | coverage span, eligibility status, **retroactive** flags, `demographics{}` |
| `PROVIDER`    | `provider_events.ndjson`      | synthetic NPI, specialty, taxonomy, addresses, billing/rendering roles |
| `PHARMACY`    | `pharmacy_events.ndjson`      | NDC, drug, days supply, quantity, fill date, prescriber/pharmacy NPI, amounts |
| `ADJUDICATION`| `adjudication_events.ndjson`  | 835-style events: `ADJUDICATED/ADJUSTED/REVERSED/VOID/DENIED`, version deltas, `paid_amount_delta` |
| *(malformed)* | `claim_events_malformed.ndjson` | a mirror copy of the bad rows injected into the streams above (for convenience) |

**CLAIM payload** includes: `claim_id`, `claim_version`, `member_id`,
`payer_id`, `plan_id`, `claim_type` (PROFESSIONAL/INSTITUTIONAL/DENTAL/…),
`claim_status` (PAID/DENIED/PENDED/REVERSED/VOID), `service_from_date`,
`service_to_date`, `received_date`, `paid_date`, `billing_provider_npi`,
`rendering_provider_npi`, `facility_npi`, `total_charge_amount`,
`allowed_amount`, `paid_amount`, `patient_responsibility`,
`denial_reason_code` (nullable),
`diagnoses[]{diagnosis_code, diagnosis_position, diagnosis_type, present_on_admission}`,
`procedures[]{procedure_code, procedure_position, procedure_date}`,
`lines[]{claim_line_id, line_number, procedure_code, revenue_code, place_of_service, service_date, units, charge_amount, allowed_amount, paid_amount}`,
plus adjustment lineage: `original_claim_id`, `adjustment_type`,
`void_indicator`, `reversal_indicator`, `adjustment_reason`.

For **clean** claim records the header totals reconcile to the sum of the line
amounts (`total_charge_amount == Σ lines.charge_amount`, etc.). Reconciliation
is intentionally **broken** only on the injected `HEADER_LINE_MISMATCH`
malformed rows.

---

## How to run

Pure standard library, Python 3.8+. No installs required.

```bash
python generate_synthetic_claims.py --members 500 --out output/ --seed 42
```

(Use `python3` if `python` is not on your PATH.)

### CLI arguments

| Flag               | Default                     | Meaning |
|--------------------|-----------------------------|---------|
| `--members`        | `500`                       | Number of synthetic members |
| `--start-date`     | `2024-01-01`                | Service window start (YYYY-MM-DD) |
| `--end-date`       | `2025-12-31`                | Service window end (YYYY-MM-DD) |
| `--seed`           | `42`                        | RNG seed — output is byte-for-byte reproducible |
| `--out`            | `output/`                   | Output directory |
| `--as-of`          | `2026-06-13T08:00:00+00:00` | `file_generation_ts` (fixed, **not** wall-clock, so runs stay reproducible) |
| `--late-rate`      | `0.08`                      | Fraction of late-arriving claims |
| `--adjust-rate`    | `0.12`                      | Fraction of claims with adjust/void/reversal chains |
| `--malformed-rate` | `0.05`                      | Fraction of malformed claims for quarantine testing |

### Determinism

All structural randomness derives from `random.Random(--seed)`; UUIDs are
generated from the seeded RNG (not OS entropy); Faker (if installed) is seeded
too. Wall-clock time is **never** used for data values. Re-running with the same
`(--seed, args)` produces identical files. This is verified by diffing two runs
with the same seed.

### Optional Faker

`requirements.txt` is empty by default. If `Faker` is installed it is used only
to flavor synthetic **names/addresses**; it never changes the schema, counts, or
determinism. The script falls back to deterministic stdlib name/address
synthesis when Faker is absent (summary prints `faker=off (stdlib)`).

### Run summary

At the end the generator prints per-file record counts and injected-event
tallies: `total, late, retro, adjustments, voids, reversals, duplicates,
malformed`. These let you reconcile the generator's intent against the bronze
layer's quarantine/dedupe counts.

---

## Deliberately injected edge cases

These exist so the downstream **bronze** pipeline can be tested. All malformed
rows are **structurally parseable JSON** — the bronze layer must *detect* the
semantic defect, not merely fail to parse. A non-authoritative
`_synthetic_defect_hint` field is attached for **reconciliation only**; the
pipeline must **not** trust it and must independently detect the defect.

| Edge case | How it shows up |
|-----------|-----------------|
| **Late-arriving claims** | `source_extract_ts` is far *after* the `business_event_ts`; `received_date` pushed 120–400 days past the service date; `payload_late_arrival: true` |
| **Retroactive eligibility** | `retro_active_indicator: true` with `retro_effective_date` backdated to *before* a prior **denied** claim's service date, so coverage now overlaps a claim previously denied for "no coverage" |
| **Adjustment chains** | original → `claim_version` N+1 with `original_claim_id` set, `adjustment_type=REPLACEMENT`; paired `ADJUSTED` adjudication event with `paid_amount_delta` |
| **Voids** | `void_indicator: true`, `claim_status=VOID`, paired `VOID` adjudication event (negative delta) |
| **Reversals** | `reversal_indicator: true`, `claim_status=REVERSED`, **negative** `paid_amount` (legal only here), paired `REVERSED` adjudication event |
| **Duplicates** | same `natural_key`, redelivered in `claims_redelivery.ndjson` — sometimes identical `payload_hash` (true dupe), sometimes a 1-cent change (logical dupe, different hash) |

### Malformed / quarantine rows (in `claim_events*.ndjson` + a mirror file)

| Defect hint                    | What is wrong |
|--------------------------------|---------------|
| `MISSING_MEMBER_ID`            | `member_id` is null (missing required business key) |
| `MISSING_CLAIM_ID`             | `claim_id` is null in payload **and** `natural_key` |
| `SERVICE_TO_BEFORE_FROM`       | `service_to_date < service_from_date` (impossible range) |
| `FUTURE_SERVICE_DATE`          | service dates 400–900 days in the future |
| `NEGATIVE_PAID_NON_ADJUSTMENT` | negative `paid_amount` on a non-reversal/non-void/non-adjustment claim |
| `HEADER_LINE_MISMATCH`         | header totals no longer reconcile to the sum of `lines[]` |

A handful of malformed **eligibility** rows (null `member_id`) are also injected
to exercise cross-file quarantine.

---

## Mapping to Snowflake stages and bronze tables

Files are loaded from a local path to a Snowflake **internal stage** via `PUT`,
then `COPY INTO` raw bronze tables.

```sql
-- 1) One internal stage per event stream (or a single stage with subpaths).
CREATE STAGE IF NOT EXISTS claims_landing
  FILE_FORMAT = (TYPE = JSON STRIP_OUTER_ARRAY = FALSE);

-- 2) PUT the local NDJSON files onto the internal stage (run from SnowSQL).
PUT file://output/claim_events.ndjson        @claims_landing/claim/        AUTO_COMPRESS=TRUE;
PUT file://output/eligibility_events.ndjson  @claims_landing/eligibility/  AUTO_COMPRESS=TRUE;
PUT file://output/provider_events.ndjson     @claims_landing/provider/     AUTO_COMPRESS=TRUE;
PUT file://output/pharmacy_events.ndjson     @claims_landing/pharmacy/     AUTO_COMPRESS=TRUE;
PUT file://output/adjudication_events.ndjson @claims_landing/adjudication/ AUTO_COMPRESS=TRUE;

-- 3) Land each NDJSON line as one VARIANT row in a raw bronze table.
CREATE TABLE IF NOT EXISTS bronze_claim_raw (
  v                 VARIANT,
  payload_hash      STRING  AS (v:payload_hash::string),
  source_file_name  STRING  AS (v:source_file_name::string),
  load_ts           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

COPY INTO bronze_claim_raw (v)
  FROM @claims_landing/claim/
  FILE_FORMAT = (TYPE = JSON)
  ON_ERROR = CONTINUE;
```

### Suggested file → stage → bronze mapping

| NDJSON file                     | Internal stage path            | Bronze raw table          |
|---------------------------------|--------------------------------|---------------------------|
| `claim_events.ndjson`           | `@claims_landing/claim/`       | `bronze_claim_raw`        |
| `eligibility_events.ndjson`     | `@claims_landing/eligibility/` | `bronze_eligibility_raw`  |
| `provider_events.ndjson`        | `@claims_landing/provider/`    | `bronze_provider_raw`     |
| `pharmacy_events.ndjson`        | `@claims_landing/pharmacy/`    | `bronze_pharmacy_raw`     |
| `adjudication_events.ndjson`    | `@claims_landing/adjudication/`| `bronze_adjudication_raw` |
| `claim_events_malformed.ndjson` | *(do not load separately)*      | mirror of bad rows already present in `claim_events.ndjson` |

> `claim_events_malformed.ndjson` is a **convenience mirror** — those rows are
> already embedded in `claim_events.ndjson`. Load it only if you specifically
> want a malformed-only fixture; otherwise you will double-count.

### Expected bronze responsibilities (what these fixtures test)

- **De-dupe** on `natural_key` + `payload_hash` (catch the injected duplicates).
- **Quarantine** rows failing data-quality rules (null business keys, impossible
  / future dates, illegal negative paid, header/line mismatch) into a
  quarantine/error table instead of promoting them.
- **Late-arrival handling**: reconcile `business_event_ts` vs `source_extract_ts`
  for out-of-order / backfilled loads.
- **Retroactive eligibility**: re-evaluate prior denied claims when coverage is
  backdated.
- **Adjustment lineage**: stitch `claim_version` chains via `original_claim_id`
  and the paired adjudication events; apply voids/reversals.

---

## Files in this directory

```
data_generator/
├── README.md                      ← this file
├── requirements.txt               ← stdlib-only; Faker optional (pinned, commented)
├── generate_synthetic_claims.py   ← the generator (single file, runnable)
└── output/                        ← NDJSON written here by default
```
