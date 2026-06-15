# =============================================================================
# Airflow image for the claims platform -- Airflow + Cosmos + dbt-snowflake +
# the moov-io/x12 `x12tojson` converter (used by the x12_to_json_bronze DAG).
# -----------------------------------------------------------------------------
# Cosmos runs in the Airflow env; dbt runs in an ISOLATED venv. The DAGs and dbt
# project are MOUNTED by docker-compose (not baked) for fast local iteration; the
# x12tojson binary must be baked, so the compose build context is the REPO ROOT
# (see docker-compose.yml: build.context=.. , dockerfile=airflow/Dockerfile).
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

# Cosmos + Snowflake provider in the Airflow env.
COPY airflow/requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt

# dbt-snowflake in its own venv (Cosmos-recommended isolation).
RUN python -m venv /home/airflow/dbt_venv \
 && /home/airflow/dbt_venv/bin/pip install --no-cache-dir --upgrade pip \
 && /home/airflow/dbt_venv/bin/pip install --no-cache-dir "dbt-snowflake==1.8.4"

# The X12->JSON converter (moov-io/x12).
USER root
COPY --from=x12build /x12tojson /usr/local/bin/x12tojson
RUN chmod 0755 /usr/local/bin/x12tojson
USER airflow
