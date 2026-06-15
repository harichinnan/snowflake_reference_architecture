# Synthea → X12 837P generator

> **⚠️ SYNTHETIC DATA — NOT REAL CMS / MEDICARE / MEDICAID / PHI.**
> Everything in this directory is produced by [Synthea](https://github.com/synthetichealth/synthea),
> an open-source **synthetic** patient generator. The patients, providers,
> payers, member ids, NPIs, and claims are entirely fictional. The generated
> X12 uses clearly-fake NPIs (10 digits starting with `9`) and synthetic
> payer/member ids. **Nothing here may be submitted to a real clearinghouse or
> payer, and none of it represents a real person or real protected health
> information.**

## What is Synthea?

Synthea is a synthetic patient population simulator. It models the full medical
history of fictional patients — encounters, conditions, procedures, medications,
and the resulting **claims** — and can export that history as CSV (and FHIR,
C-CDA, etc.). We use the CSV export as a realistic-but-fake source of
health-care claim data.

## Pipeline

This directory is the first stage of a reference data pipeline:

```
  Synthea  ──►  CSV output        (run_synthea.sh)
            │   output/csv/*.csv
            │
            ▼
  synthea_to_x12.py  ──►  X12 837P EDI files
                          output/x12/claims_837p_*.x12
            │
            ▼
  Snowflake bronze (raw X12 text loaded verbatim)
            │
            ▼
  Airflow + moov-io/x12  (x12/x12tojson --rule 837p)
            │   parse X12 → flat, labeled JSON segment stream
            ▼
  Snowflake bronze (JSON segments)
            │
            ▼
  dbt canonical models   (flatten `segments`, filter by _segment + claim_seq)
```

* **Synthea CSV → X12 837P** — `synthea_to_x12.py` joins the Synthea CSVs
  (`claims`, `claims_transactions`, `patients`, `providers`, `organizations`,
  `payers`) and emits X12 837P (Professional) claims. The segment structure
  mirrors `x12/sample_837p.txt`, which is the shape the project's
  `moov-io/x12` (`rule_5010_837p`) parser expects.
* **X12 → JSON** — the Go tool `x12/x12tojson` parses each X12 file and emits a
  flat, labeled segment stream. A subscriber-level `HL` segment (`HL03 == 22`)
  starts a new claim, so all segments belonging to one claim share a
  `claim_seq`; file/billing-provider segments are `claim_seq 0`.
* **JSON → canonical** — dbt flattens the `segments` array and filters by
  `_segment` + `claim_seq` to build canonical claim / service-line tables.

## X12 details

The 837P files use the delimiters expected by the project's parser:

| role                         | char |
|------------------------------|------|
| element separator            | `*`  |
| segment terminator           | `~`  (also one segment per line) |
| component / sub-element sep   | `<`  (the ISA16 in the sample — **not** `:`) |
| repetition separator         | `^`  |

Each output file is one ISA/GS/ST interchange containing the shared billing
provider loop (`HL*1`) plus one subscriber `HL` loop per claim (`CLM`, `HI`
diagnoses, rendering `NM1*82`, and `LX`/`SV1`/`DTP` service lines). Control
numbers (ISA/GS/ST/SE/GE/IEA) are kept consistent and the `SE` segment count
covers `ST..SE` inclusive.

## How to run

### 1. Generate synthetic data with Synthea

```bash
# 25 patients, seed 42, CSV only (default)
./run_synthea.sh

# bigger population / different seed
POPULATION=100 SEED=7 ./run_synthea.sh

# generate AND convert to X12 in one step
RUN_X12=1 ./run_synthea.sh
```

`run_synthea.sh` downloads `synthea-with-dependencies.jar` (master-branch-latest
release) only if it is missing, runs Synthea with CSV export into `output/csv/`,
and (when `RUN_X12=1`) calls the converter. Requires `java` and either `curl`
or `wget`.

### 2. Convert existing Synthea CSVs to X12 837P

```bash
python3 synthea_to_x12.py \
  --csv-dir output/csv \
  --out-dir output/x12 \
  --claims-per-file 50 \
  --max-claims 300 \
  --seed 42
```

Pure standard library, deterministic (same CSVs + same `--seed` ⇒
byte-identical output). Only claims with at least one `TYPE='CHARGE'`
transaction line are emitted. Claims are capped at `--max-claims` (reported,
never silently truncated) and batched `--claims-per-file` per interchange file
(`claims_837p_0001.x12`, `claims_837p_0002.x12`, …).

### 3. Validate the X12 parses

From the repo root:

```bash
./x12/x12tojson --rule 837p data_generator/synthea/output/x12/claims_837p_0001.x12
```

This should exit `0` (no parse error) and emit a JSON segment stream containing
`CLM`, `SV1`, and `HI` segments with `claim_seq > 0`.

## Files

| file                  | purpose                                              |
|-----------------------|------------------------------------------------------|
| `run_synthea.sh`      | download + run Synthea (CSV export), optional X12     |
| `synthea_to_x12.py`   | Synthea CSV → X12 837P converter (stdlib, deterministic) |
| `output/csv/`         | Synthea CSV export (input to the converter)          |
| `output/x12/`         | generated X12 837P files                             |
| `README.md`           | this file                                            |
