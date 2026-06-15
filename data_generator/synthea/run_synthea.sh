#!/usr/bin/env bash
#
# run_synthea.sh -- generate a synthetic patient population with Synthea
# (synthetichealth/synthea) and export it as CSV, then optionally convert that
# CSV output into X12 837P EDI files via synthea_to_x12.py.
#
#   ###############################################################
#   #  SYNTHETIC DATA -- NOT REAL CMS / MEDICARE / MEDICAID / PHI. #
#   #  Synthea generates entirely fictional patients. Nothing      #
#   #  produced here represents a real person or a real claim.     #
#   ###############################################################
#
# The script is idempotent:
#   * the Synthea jar is downloaded only if it is not already present;
#   * Synthea is re-run each time (it overwrites output/csv);
#   * the X12 conversion step is opt-in via RUN_X12=1.
#
# Usage:
#   ./run_synthea.sh                 # 25 patients, seed 42, CSV only
#   POPULATION=100 SEED=7 ./run_synthea.sh
#   RUN_X12=1 ./run_synthea.sh       # also build X12 from the CSV
#
# Environment overrides:
#   POPULATION   number of living patients to generate   (default 25)
#   SEED         Synthea random seed                       (default 42)
#   STATE        US state to generate in                   (default Massachusetts)
#   RUN_X12      if "1", run synthea_to_x12.py afterwards  (default 0)
#   MAX_CLAIMS   passed to synthea_to_x12.py --max-claims  (default 300)
#
set -euo pipefail

# Resolve the directory this script lives in (so it works from anywhere).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- Configuration (override via environment) ----
POPULATION="${POPULATION:-25}"
SEED="${SEED:-42}"
STATE="${STATE:-Massachusetts}"
RUN_X12="${RUN_X12:-0}"
MAX_CLAIMS="${MAX_CLAIMS:-300}"

JAR="synthea-with-dependencies.jar"
# master-branch-latest release of the standalone, all-deps Synthea jar.
JAR_URL="https://github.com/synthetichealth/synthea/releases/download/master-branch-latest/synthea-with-dependencies.jar"

OUT_DIR="output"
CSV_DIR="$OUT_DIR/csv"

echo "=============================================================="
echo " Synthea synthetic data generation  (NOT REAL CMS/PHI)"
echo "=============================================================="
echo "  population : $POPULATION"
echo "  seed       : $SEED"
echo "  state      : $STATE"
echo "  run x12    : $RUN_X12"
echo "--------------------------------------------------------------"

# ---- 1. Download the Synthea jar if missing (idempotent) ----
if [[ ! -f "$JAR" ]]; then
  echo "Synthea jar not found -- downloading from master-branch-latest ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$JAR" "$JAR_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$JAR" "$JAR_URL"
  else
    echo "ERROR: need curl or wget to download $JAR" >&2
    exit 1
  fi
  echo "Downloaded $JAR."
else
  echo "Synthea jar already present -- skipping download."
fi

# ---- 2. Run Synthea with CSV export into output/csv ----
# Flags:
#   -p <n>                       population size (living patients)
#   -s <seed>                    random seed (reproducible)
#   --exporter.csv.export true   enable CSV exporter
#   --exporter.baseDirectory     where Synthea writes output
#   --exporter.fhir.export false disable FHIR (we only want CSV here)
echo "Running Synthea ..."
java -jar "$JAR" \
  -p "$POPULATION" \
  -s "$SEED" \
  --exporter.csv.export true \
  --exporter.fhir.export false \
  --exporter.hospital.fhir.export false \
  --exporter.practitioner.fhir.export false \
  --exporter.baseDirectory "$OUT_DIR" \
  "$STATE"

if [[ ! -f "$CSV_DIR/claims.csv" ]]; then
  echo "ERROR: expected $CSV_DIR/claims.csv was not produced." >&2
  exit 1
fi
echo "Synthea CSV export complete -> $CSV_DIR"

# ---- 3. Optionally convert CSV -> X12 837P ----
if [[ "$RUN_X12" == "1" ]]; then
  echo "--------------------------------------------------------------"
  echo "Converting Synthea CSV -> X12 837P ..."
  python3 synthea_to_x12.py \
    --csv-dir "$CSV_DIR" \
    --out-dir "$OUT_DIR/x12" \
    --max-claims "$MAX_CLAIMS" \
    --seed "$SEED"
else
  echo "Skipping X12 conversion (set RUN_X12=1 to enable)."
  echo "To convert manually:"
  echo "  python3 synthea_to_x12.py --csv-dir $CSV_DIR --out-dir $OUT_DIR/x12"
fi

echo "Done."
