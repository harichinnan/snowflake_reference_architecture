"""
claims_dbt_cosmos
=================
Run the claims-platform dbt project as a native Airflow DAG using
astronomer-cosmos. Cosmos parses the dbt project and renders each dbt resource
(seed -> model -> test) as its own Airflow task with the correct dependencies,
so the medallion build (BRONZE -> SILVER -> GOLD -> SEMANTIC) plus the DCM
control models and data-quality tests run as a first-class Airflow pipeline.

This is one of several ways to orchestrate the same dbt project:
  * Airflow + Cosmos (this DAG)        -- portable, rich scheduling/retries/alerting
  * dbt Projects on Snowflake          -- EXECUTE DBT PROJECT, runs inside Snowflake
  * GitHub Actions                     -- CI/CD-driven dbt Core runs
All three execute the SAME models in ../dbt.

Connection: an Airflow Snowflake connection `snowflake_claims` (set via
AIRFLOW_CONN_SNOWFLAKE_CLAIMS in .env). Cosmos maps it into a dbt profile.

Data is SYNTHETIC -- not real CMS/Medicare/Medicaid/PHI.
"""

import os
from datetime import datetime

from cosmos import (
    DbtDag,
    ProjectConfig,
    ProfileConfig,
    ExecutionConfig,
    RenderConfig,
)
from cosmos.constants import LoadMode
from cosmos.profiles import SnowflakeUserPasswordProfileMapping

# Paths inside the container (see docker-compose.yml volumes + Dockerfile venv).
DBT_PROJECT_DIR = os.environ.get("DBT_PROJECT_DIR", "/opt/airflow/dbt_project")
DBT_VENV_DIR = os.environ.get("DBT_VENV_DIR", "/home/airflow/dbt_venv")
DBT_EXECUTABLE = f"{DBT_VENV_DIR}/bin/dbt"

# Map the Airflow `snowflake_claims` connection into the dbt profile
# `claims_platform` (the profile name in dbt/dbt_project.yml), target `dev`.
# profile_args override/augment the connection (db/schema/warehouse/role).
profile_config = ProfileConfig(
    profile_name="claims_platform",
    target_name="dev",
    profile_mapping=SnowflakeUserPasswordProfileMapping(
        conn_id="snowflake_claims",
        profile_args={
            "database": "CLAIMS_DEV",
            # Default schema; the project's generate_schema_name override routes
            # each model to its real schema (BRONZE/SILVER_*/GOLD/...).
            "schema": "CONTROL",
            "warehouse": "WH_CLAIMS_TRANSFORM",
            "role": "CLAIMS_TRANSFORMER",
            "threads": 4,
        },
    ),
)

project_config = ProjectConfig(dbt_project_path=DBT_PROJECT_DIR)

execution_config = ExecutionConfig(dbt_executable_path=DBT_EXECUTABLE)

# The project is dependency-free (packages.yml is disabled), so no `dbt deps`.
# DBT_LS renders the graph by running `dbt ls` at parse time. For production,
# consider LoadMode.DBT_MANIFEST against a committed manifest to avoid parsing
# dbt on every scheduler heartbeat.
render_config = RenderConfig(
    load_method=LoadMode.DBT_LS,
    dbt_executable_path=DBT_EXECUTABLE,
)

claims_dbt_cosmos = DbtDag(
    project_config=project_config,
    profile_config=profile_config,
    execution_config=execution_config,
    render_config=render_config,
    operator_args={
        # Dependency-free project -> never run `dbt deps`.
        "install_deps": False,
        # Surface dbt stdout in the Airflow task logs.
        "append_env": True,
    },
    # Scheduling / Airflow DAG params.
    dag_id="claims_dbt_cosmos",
    schedule="@daily",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args={"retries": 1},
    tags=["dbt", "cosmos", "snowflake", "claims"],
)
