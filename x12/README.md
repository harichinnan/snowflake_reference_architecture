# x12tojson — X12 837 → labeled JSON (moov-io/x12)

> Synthetic data — not real CMS/Medicare/Medicaid/PHI.

A tiny Go CLI that parses X12 EDI health-care claims (837P / 837D) with
[moov-io/x12](https://github.com/moov-io/x12) and emits **navigable JSON** for
Snowflake. It is built into the Airflow image and invoked by the
`x12_to_json_bronze` DAG, which loads the JSON into `BRONZE.BR_RAW_X12_CLAIM_JSON`
for the dbt canonical models (`silver_canonical/x12`).

## Why a wrapper

moov-io/x12 parses X12 into a **rule-positional** tree where segments carry only
element positions (`"01"`, `"02"`, …) and **no segment name** — so you can't tell
a `CLM` (claim) from an `NM1` (name) in SQL. Each moov segment type *does* expose
`Name()`, so this tool walks the parsed document in order and emits a **flat,
labeled segment stream** with a `claim_seq` (incremented per subscriber `HL`
loop, `HL03="22"`), which is trivial to `LATERAL FLATTEN` in dbt:

```json
{
  "interchange_control_number": "000000001",
  "transaction_type": "837p",
  "segment_count": 1146,
  "segments": [
    {"_segment":"NM1","claim_seq":0,"01":"85","03":"BILLING ORG","09":"9000000001"},
    {"_segment":"HL","claim_seq":1,"01":"2","03":"22","04":"0"},
    {"_segment":"CLM","claim_seq":1,"01":"<claimid>","02":"553.96","05":{"01":"11"}},
    {"_segment":"HI","claim_seq":1,"01":{"01":"BK","02":"<dx>"}},
    {"_segment":"LX","claim_seq":1,"01":"1"},
    {"_segment":"SV1","claim_seq":1,"01":"HC<97530","02":"174","04":"3"},
    {"_segment":"DTP","claim_seq":1,"01":"472","02":"D8","03":"20240118"}
  ]
}
```

## Build & use

```bash
go build -o x12tojson .                 # or: docker build -t x12tojson .
./x12tojson --rule 837p claim.x12       # flat labeled JSON (default)
cat claim.x12 | ./x12tojson --rule 837p # stdin
./x12tojson --rule 837p --tree claim.x12   # raw moov nested tree instead
./x12tojson --rule 837p --pretty claim.x12 # indented
```

Flags: `--rule 837p|837d`, `--tree` (raw moov tree), `--pretty`. Input is a file
path or `-`/stdin. `sample_837p.txt` is a moov-parseable reference;
`sample_837p.flat.json` is its labeled output.

## In the platform

```
Synthea CSV --(data_generator/synthea/synthea_to_x12.py)--> .x12 (837P)
  --(PUT + COPY, raw as-is)--> BRONZE.BR_RAW_X12_837
  --(Airflow x12_to_json_bronze: x12tojson here)--> BRONZE.BR_RAW_X12_CLAIM_JSON (VARIANT)
  --(dbt silver_canonical/x12)--> claim_header_x12 / claim_line_x12 / claim_diagnosis_x12
```
