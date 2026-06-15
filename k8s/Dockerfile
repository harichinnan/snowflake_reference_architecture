# =============================================================================
# Airflow image for KUBERNETES (Helm) deployment of the claims dbt pipeline.
# -----------------------------------------------------------------------------
# Bakes in: the DAGs, the dbt project, Cosmos, an isolated dbt-snowflake venv,
# and the `x12tojson` binary (built from ../x12 via moov-io/x12) used by the
# x12_to_json_bronze DAG to parse X12 837P claims to JSON.
#
# BUILD CONTEXT MUST BE THE REPO ROOT:
#   docker build -f k8s/Dockerfile -t claims-airflow:local .
#
# Data is SYNTHETIC -- not real CMS/Medicare/Medicaid/PHI.
# =============================================================================

# ---- stage 1: build the moov-io/x12 -> JSON converter -----------------------
FROM golang:1.23-bookworm AS x12build
WORKDIR /build
COPY x12/go.mod x12/go.sum ./
RUN go mod download
COPY x12/*.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /x12tojson .

# ---- stage 2: the Airflow image --------------------------------------------
FROM apache/airflow:2.10.5-python3.11

USER airflow

# Cosmos + Snowflake provider (Airflow env).
COPY airflow/requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt

# dbt-snowflake in its own venv (Cosmos-recommended isolation).
RUN python -m venv /home/airflow/dbt_venv \
 && /home/airflow/dbt_venv/bin/pip install --no-cache-dir --upgrade pip \
 && /home/airflow/dbt_venv/bin/pip install --no-cache-dir "dbt-snowflake==1.8.4"

# The X12->JSON converter (moov-io/x12), used by the x12_to_json_bronze DAG.
USER root
COPY --from=x12build /x12tojson /usr/local/bin/x12tojson
RUN chmod 0755 /usr/local/bin/x12tojson
USER airflow

# Bake the DAGs and the dbt project into the image.
COPY --chown=airflow:0 airflow/dags/ /opt/airflow/dags/
COPY --chown=airflow:0 dbt/          /opt/airflow/dbt_project/
