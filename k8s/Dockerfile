# =============================================================================
# Airflow image for KUBERNETES (Helm) deployment of the claims dbt pipeline.
# -----------------------------------------------------------------------------
# Unlike airflow/Dockerfile (compose, host-mounted), this image BAKES the DAGs
# and the dbt project in -- k8s pods don't mount your laptop's filesystem.
#
# BUILD CONTEXT MUST BE THE REPO ROOT:
#   docker build -f k8s/Dockerfile -t claims-airflow:local .
#
# Cosmos runs in the Airflow env; dbt-snowflake runs in an isolated venv.
# Data is SYNTHETIC -- not real CMS/Medicare/Medicaid/PHI.
# =============================================================================
FROM apache/airflow:2.10.5-python3.11

USER airflow

# Cosmos + Snowflake provider (Airflow env).
COPY airflow/requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt

# dbt-snowflake in its own venv (Cosmos-recommended isolation).
RUN python -m venv /home/airflow/dbt_venv \
 && /home/airflow/dbt_venv/bin/pip install --no-cache-dir --upgrade pip \
 && /home/airflow/dbt_venv/bin/pip install --no-cache-dir "dbt-snowflake==1.8.9"

# Bake the DAGs and the dbt project into the image.
COPY --chown=airflow:0 airflow/dags/ /opt/airflow/dags/
COPY --chown=airflow:0 dbt/          /opt/airflow/dbt_project/
