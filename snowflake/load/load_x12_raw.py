#!/usr/bin/env python3
"""
load_x12_raw.py -- ingest raw X12 837P files AS-IS into RAW_LANDING.BR_RAW_X12_837.

One bronze row per .x12 file: the entire EDI text is stored verbatim in
`x12_raw`, with the interchange control number (ISA13) as the natural key. The
Airflow DAG `x12_to_json_bronze` then parses these rows to JSON with moov-io/x12.

Connection: reads a snow CLI connection from SNOWFLAKE_HOME/.snowflake config
(default connection `my_example_connection`) or standard SNOWFLAKE_* env vars.

  python snowflake/load/load_x12_raw.py --x12-dir data_generator/synthea/output/x12

Data is SYNTHETIC -- not real CMS/Medicare/Medicaid/PHI.
"""
import argparse
import hashlib
import os
import pathlib
import sys
import tomllib

import snowflake.connector


def conn_args() -> dict:
    """Resolve Snowflake connection args from the snow config.toml or env."""
    home = os.environ.get("SNOWFLAKE_HOME", os.path.expanduser("~/.snowflake"))
    cfg_path = pathlib.Path(home) / "config.toml"
    name = os.environ.get("SNOWFLAKE_CONNECTION", "my_example_connection")
    if cfg_path.exists():
        c = tomllib.load(open(cfg_path, "rb"))["connections"][name]
        return {
            "account": c["account"], "user": c["user"],
            "password": c.get("password"), "role": c.get("role", "CLAIMS_LOADER"),
            "warehouse": c.get("warehouse", "WH_CLAIMS_LOAD"),
            "database": "CLAIMS_DEV", "schema": "RAW_LANDING",
        }
    return {
        "account": os.environ["SNOWFLAKE_ACCOUNT"], "user": os.environ["SNOWFLAKE_USER"],
        "password": os.environ.get("SNOWFLAKE_PASSWORD"),
        "role": os.environ.get("SNOWFLAKE_ROLE", "CLAIMS_LOADER"),
        "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE", "WH_CLAIMS_LOAD"),
        "database": "CLAIMS_DEV", "schema": "BRONZE",
    }


def isa13(x12: str) -> str:
    """Interchange control number = the 13th element of the ISA segment."""
    isa = x12.lstrip().split("~", 1)[0]
    parts = isa.split("*")
    return parts[13].strip() if len(parts) > 13 else ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--x12-dir", default="data_generator/synthea/output/x12")
    args = ap.parse_args()

    files = sorted(pathlib.Path(args.x12_dir).glob("*.x12"))
    if not files:
        print(f"no .x12 files in {args.x12_dir}", file=sys.stderr)
        return 1

    cn = snowflake.connector.connect(**conn_args())
    cur = cn.cursor()
    loaded = 0
    for f in files:
        raw = f.read_text()
        eid = hashlib.sha256(f.name.encode()).hexdigest()
        cur.execute(
            """
            INSERT INTO CLAIMS_DEV.RAW_LANDING.BR_RAW_X12_837
              (bronze_event_id, source_system, source_file_name, source_file_row_number,
               event_type, natural_key, x12_raw, payload_hash, record_status,
               source_extract_ts, business_event_ts)
            SELECT %(eid)s, 'SYNTHEA_X12_837P', %(fn)s, 1, 'X12_837P',
                   %(nk)s, %(raw)s, SHA2(%(raw)s, 256), 'LANDED',
                   CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
            """,
            {"eid": eid, "fn": f.name, "nk": isa13(raw), "raw": raw},
        )
        loaded += 1
    cn.commit()
    cur.close()
    cn.close()
    print(f"loaded {loaded} raw X12 file(s) into RAW_LANDING.BR_RAW_X12_837")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
