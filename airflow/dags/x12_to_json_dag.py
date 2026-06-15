"""
x12_to_json_bronze
==================
Airflow pipeline that converts raw X12 837P claims (already ingested AS-IS into
RAW_LANDING.BR_RAW_X12_837) into JSON using the moov-io/x12 parser, and loads the
JSON back into RAW_LANDING.BR_RAW_X12_CLAIM_JSON as a VARIANT payload. A dbt canonical
model (silver_canonical/x12) then builds claim header/line/diagnosis entities
from that JSON.

Pipeline position:
  Synthea CSV --(synthea_to_x12.py)--> .x12 files
  --(PUT + COPY / load_x12_raw.py)--> RAW_LANDING.BR_RAW_X12_837  (raw, as-is)
  --(THIS DAG: x12tojson = moov-io/x12)--> RAW_LANDING.BR_RAW_X12_CLAIM_JSON (JSON)
  --(dbt: silver_canonical/x12)--> canonical claims.

The `x12tojson` binary (built from ../x12, baked into the Airflow image) is
invoked per row over stdin. Connection: Airflow conn `snowflake_claims`.

Data is SYNTHETIC -- not real CMS/Medicare/Medicaid/PHI.
"""

import json
import os
import subprocess
from datetime import datetime

from airflow.decorators import dag, task

X12TOJSON_BIN = os.environ.get("X12TOJSON_BIN", "/usr/local/bin/x12tojson")
SNOWFLAKE_CONN_ID = os.environ.get("SNOWFLAKE_CONN_ID", "snowflake_claims")
BATCH_LIMIT = int(os.environ.get("X12_BATCH_LIMIT", "500"))


def _snowflake_cursor():
    """Cursor from the Airflow Snowflake connection (provider hook)."""
    from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook

    return SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID).get_conn().cursor()


@dag(
    dag_id="x12_to_json_bronze",
    schedule=None,  # triggered after raw X12 is ingested
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["x12", "837p", "moov-io", "bronze", "snowflake"],
    doc_md=__doc__,
)
def x12_to_json_bronze():

    @task
    def fetch_unprocessed() -> list[dict]:
        """Pull raw X12 rows that have not yet been parsed to JSON."""
        cur = _snowflake_cursor()
        cur.execute(
            f"""
            SELECT bronze_event_id, source_file_name, natural_key, x12_raw
            FROM CLAIMS_DEV.RAW_LANDING.BR_RAW_X12_837
            WHERE record_status = 'LANDED'
            LIMIT {BATCH_LIMIT}
            """
        )
        rows = [
            {"bronze_event_id": r[0], "source_file_name": r[1],
             "natural_key": r[2], "x12_raw": r[3]}
            for r in cur.fetchall()
        ]
        cur.close()
        print(f"fetched {len(rows)} unprocessed X12 row(s)")
        return rows

    @task
    def convert(rows: list[dict]) -> list[dict]:
        """Run moov-io/x12 (x12tojson) on each raw X12 -> labeled JSON."""
        out = []
        for r in rows:
            proc = subprocess.run(
                [X12TOJSON_BIN, "--rule", "837p"],
                input=(r["x12_raw"] or "").encode(),
                capture_output=True,
            )
            if proc.returncode != 0:
                # Quarantine on parse failure rather than failing the whole batch.
                out.append({**r, "ok": False, "error": proc.stderr.decode()[:2000], "json": None})
                continue
            doc = json.loads(proc.stdout.decode())
            icn = doc.get("interchange_control_number") or r["natural_key"]
            out.append({**r, "ok": True, "icn": icn, "json": json.dumps(doc)})
        print(f"converted {sum(1 for x in out if x['ok'])}/{len(out)} ok")
        return out

    @task
    def load(parsed: list[dict]) -> int:
        """Load JSON into BR_RAW_X12_CLAIM_JSON; mark raw rows PROCESSED/QUARANTINE."""
        cur = _snowflake_cursor()
        loaded = 0
        for p in parsed:
            if p["ok"]:
                cur.execute(
                    """
                    INSERT INTO CLAIMS_DEV.RAW_LANDING.BR_RAW_X12_CLAIM_JSON
                      (bronze_event_id, source_system, source_file_name,
                       source_file_row_number, event_type, natural_key,
                       payload, payload_hash, record_status, source_x12_event_id)
                    SELECT SHA2(%(eid)s || ':json', 256), 'X12_837P_MOOV_JSON',
                           %(fn)s, 1, 'X12_837P_JSON', %(icn)s,
                           PARSE_JSON(%(js)s), SHA2(%(js)s, 256), 'VALID', %(eid)s
                    """,
                    {"eid": p["bronze_event_id"], "fn": p["source_file_name"],
                     "icn": p["icn"], "js": p["json"]},
                )
                cur.execute(
                    "UPDATE CLAIMS_DEV.RAW_LANDING.BR_RAW_X12_837 "
                    "SET record_status='PROCESSED', updated_at=CURRENT_TIMESTAMP() "
                    "WHERE bronze_event_id=%(eid)s",
                    {"eid": p["bronze_event_id"]},
                )
                loaded += 1
            else:
                cur.execute(
                    "UPDATE CLAIMS_DEV.RAW_LANDING.BR_RAW_X12_837 "
                    "SET record_status='QUARANTINE', quarantine_reason=%(err)s, "
                    "    updated_at=CURRENT_TIMESTAMP() WHERE bronze_event_id=%(eid)s",
                    {"err": p.get("error", "parse error")[:500], "eid": p["bronze_event_id"]},
                )
        cur.connection.commit()
        cur.close()
        print(f"loaded {loaded} JSON payload(s) into BR_RAW_X12_CLAIM_JSON")
        return loaded

    load(convert(fetch_unprocessed()))


x12_to_json_bronze()
