# Orchestrating the dbt pipeline with Airflow + Cosmos

> Synthetic data — not real CMS/Medicare/Medicaid/PHI.

This is a containerized **Apache Airflow** stack that runs the claims-platform dbt
project using **[astronomer-cosmos](https://astronomer.github.io/astronomer-cosmos/)**.
Cosmos parses the dbt project under [`../dbt`](../dbt) and renders **every dbt
resource (seed → model → test) as its own Airflow task**, with dependencies
matching the dbt DAG — so the medallion build (`BRONZE → SILVER_CANONICAL →
SILVER_DIMENSIONAL → GOLD → SEMANTIC`), the `CONTROL`/`AUDIT` models, and the
data-quality tests run as a first-class, observable Airflow pipeline with
retries, scheduling, and alerting.

It's an **alternative orchestrator** for the *same* dbt project — pick whichever
fits your environment:

| Orchestrator | Where dbt runs | Notes |
|---|---|---|
| **Airflow + Cosmos** (this dir) | Airflow workers (Docker) | Rich scheduling/retries/alerting; per-model task graph |
| dbt Projects on Snowflake | Inside Snowflake | `EXECUTE DBT PROJECT`; see [`docs/dbt_on_snowflake.md`](../docs/dbt_on_snowflake.md) |
| GitHub Actions | CI runner | CI/CD-gated dbt Core runs |

## Contents

```
airflow/
  Dockerfile            # Airflow + Cosmos; dbt-snowflake in an isolated venv
  docker-compose.yml    # LocalExecutor + Postgres; mounts ../dbt
  requirements.txt      # astronomer-cosmos + Snowflake provider
  .env.example          # AIRFLOW_CONN_SNOWFLAKE_CLAIMS + web login
  dags/
    claims_dbt_cosmos_dag.py   # the Cosmos DbtDag
```

## Prerequisites

- Docker + Docker Compose.
- A reachable Snowflake account with the platform objects created (roles,
  warehouses, `CLAIMS_DEV`, schemas, control/audit/bronze tables). Provision them
  with the [`dcm/`](../dcm) project or `snowflake/setup/`.
- The reference seeds and synthetic data don't have to be pre-loaded — the DAG
  runs `dbt seed`; load bronze data with `make stage-load` (or your own ingestion)
  before the silver/gold models will have rows.

## Run it

```bash
cd airflow
cp .env.example .env
# edit .env -> set AIRFLOW_CONN_SNOWFLAKE_CLAIMS (account/user/password/role)

docker compose up --build         # first build takes a few minutes
# open http://localhost:8080  (admin / admin)
# un-pause + trigger the `claims_dbt_cosmos` DAG
```

Tear down: `docker compose down` (add `-v` to also drop the Postgres volume).

## How the Snowflake connection works

The DAG uses the Airflow connection **`snowflake_claims`**, supplied by
`AIRFLOW_CONN_SNOWFLAKE_CLAIMS` in `.env` (JSON). Cosmos's
`SnowflakeUserPasswordProfileMapping` maps that connection into a dbt profile
named `claims_platform` (matching `dbt/dbt_project.yml`), target `dev`, and
`profile_args` set `database=CLAIMS_DEV`, `warehouse=WH_CLAIMS_TRANSFORM`,
`role=CLAIMS_TRANSFORMER`. The project's `generate_schema_name` override routes
each model to its real schema (`BRONZE`, `SILVER_*`, `GOLD`, …) regardless of the
profile's default schema.

Prefer key-pair auth for shared/headless use: put
`"private_key_file": "/opt/airflow/keys/rsa_key.p8"` in the connection `extra`,
mount the key into the container, and drop `password` (see `.env.example`).

## Notes & production hardening

- **dbt isolation:** dbt-snowflake is installed in a separate venv
  (`/home/airflow/dbt_venv`) so its dependencies never clash with Airflow's; the
  DAG points Cosmos at it via `ExecutionConfig(dbt_executable_path=...)`.
- **Dependency-free project:** the dbt project has no external packages
  (`packages.yml` is disabled; macros are vendored), so the DAG sets
  `install_deps=False` and never runs `dbt deps`.
- **Render mode:** the DAG uses `LoadMode.DBT_LS` (runs `dbt ls` at parse time).
  For production, switch to `LoadMode.DBT_MANIFEST` against a committed
  `manifest.json` so the scheduler doesn't invoke dbt on every heartbeat.
- **Executor:** this compose uses `LocalExecutor` + Postgres for a single-host
  demo. For scale, move to `CeleryExecutor`/`KubernetesExecutor`.
- **Selecting a subset:** Cosmos honors dbt selectors via `RenderConfig(select=...)
  / exclude=...` if you only want, say, `silver_canonical+`.
