# =============================================================================
# Airflow image for the claims platform — Airflow + Cosmos + dbt-snowflake
# -----------------------------------------------------------------------------
# Cosmos runs in the Airflow Python environment; dbt runs in an ISOLATED
# virtualenv (/home/airflow/dbt_venv) so dbt's deps never conflict with
# Airflow's. The DAG points Cosmos at that venv's dbt via ExecutionConfig.
# =============================================================================
FROM apache/airflow:2.10.5-python3.11

USER airflow

# Cosmos + Snowflake provider in the Airflow env.
COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt

# dbt-snowflake in its own venv (Cosmos-recommended isolation).
RUN python -m venv /home/airflow/dbt_venv \
 && /home/airflow/dbt_venv/bin/pip install --no-cache-dir --upgrade pip \
 && /home/airflow/dbt_venv/bin/pip install --no-cache-dir "dbt-snowflake==1.8.4"
