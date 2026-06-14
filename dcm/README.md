# Infrastructure as a Snowflake DCM Project (Declarative Change Management)

> Synthetic data — not real CMS/Medicare/Medicaid/PHI.

This directory is a **Snowflake DCM project** — the declarative, Snowflake-native
replacement for the imperative numbered setup scripts. Instead of running ordered
`CREATE` scripts via `snow sql`, you describe the **desired state** of the
platform's infrastructure with `DEFINE` statements, and Snowflake computes and
applies the diff (`CREATE` / `ALTER` / `DROP`) — all **inside** Snowflake as a
schema-level `PROJECT` object. This is the infra counterpart to *dbt Projects on
Snowflake* (which owns the transformations).

Docs: <https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-overview>

## Layout

```
dcm/
  manifest.yml                      # project config: targets (DEV/PROD) + templating
  sources/
    definitions/
      00_roles.sql                  # DEFINE ROLE x7 + role hierarchy   (was setup 001)
      01_warehouses.sql             # DEFINE WAREHOUSE x5                (was setup 002)
      02_databases_schemas.sql      # DEFINE DATABASE + 10 schemas       (was setup 003)
      03_control_tables.sql         # DEFINE TABLE CONTROL.* x9          (was setup 005)
      04_audit_tables.sql           # DEFINE TABLE AUDIT.* x4            (was setup 006)
      05_bronze_landing.sql         # DEFINE TABLE BRONZE.BR_RAW_* x5    (was setup 006)
      07_semantic_tables.sql        # DEFINE TABLE SEMANTIC doc tables   (was setup 012)
      08_grants.sql                 # least-privilege grants             (was 002/003/004/005/012/014)
    macros/                         # optional global Jinja macros
  out/                              # command artifacts (git-ignored)
```

## What DCM manages vs. what stays imperative

DCM `DEFINE` supports a fixed set of object types. The platform splits cleanly:

| Managed by **this DCM project** | Stays **imperative** (`snowflake/setup/`) — DCM can't `DEFINE` it |
|---|---|
| Roles, warehouses, databases, schemas | File formats + internal stages (`004`) |
| `CONTROL.*`, `AUDIT.*`, `BRONZE.BR_RAW_*`, `SEMANTIC` doc tables | Streams + tasks (`007`) |
| Least-privilege grants | Cortex Search / Agent (`009`, `010`), Snowflake-managed MCP (`011`) |
| | Semantic VIEW + MCP views (`012`) — depend on dbt GOLD models |
| | External access integration + `DBT PROJECT` object (`013`) |
| | **Seed DML** — `PIPELINE_CONFIG` / `DATA_CONTRACT` rows (DCM is DDL-only) |

The transformation tables (BRONZE models, SILVER, GOLD, SEMANTIC views) are owned
by **dbt**, not DCM — DCM only provisions the empty landing/control/audit tables
and the schemas dbt builds into.

## One-time bootstrap (not in DCM)

The `PROJECT` object must live somewhere other than the database it manages:

```sql
-- run once as ACCOUNTADMIN
CREATE DATABASE IF NOT EXISTS OPS_DB;
CREATE SCHEMA  IF NOT EXISTS OPS_DB.DCM;
```

## Deploy

```bash
# Preview the change set (dry run) -- writes out/plan_result.json
snow dcm plan   OPS_DB.DCM.CLAIMS_INFRA_DCM_DEV --from dcm --target DCM_DEV -c my_example_connection

# Create the project object (first time)
snow dcm create OPS_DB.DCM.CLAIMS_INFRA_DCM_DEV --from dcm --target DCM_DEV -c my_example_connection

# Apply
snow dcm deploy OPS_DB.DCM.CLAIMS_INFRA_DCM_DEV --from dcm --target DCM_DEV -c my_example_connection

# Prod is a config swap (database => CLAIMS_PROD via the PROD configuration)
snow dcm deploy OPS_DB.DCM.CLAIMS_INFRA_DCM_PROD --from dcm --target DCM_PROD -c my_example_connection
```

Equivalent native SQL once the project object exists:

```sql
EXECUTE DCM PROJECT OPS_DB.DCM.CLAIMS_INFRA_DCM_DEV PLAN;     -- preview
EXECUTE DCM PROJECT OPS_DB.DCM.CLAIMS_INFRA_DCM_DEV DEPLOY;   -- apply
```

Makefile shortcuts: `make dcm-plan` and `make dcm-deploy`.

## ⚠️ Prune behavior — important

DCM is **convergent**: objects that exist in the target but are **no longer
defined are DROPPED**. Two consequences:

1. **Always `plan` first.** Review `out/plan_result.json` before `deploy`.
2. **Adopting an already-built account:** this repo's account was first built
   imperatively, so the managed schemas also contain objects DCM does **not**
   define (stages, streams, tasks, Cortex services, the dbt project, dbt-built
   models). Deploying DCM against those schemas could try to drop them. Prefer
   deploying DCM to a **fresh** database, or scope/raise this with the
   `plan` output before applying. DCM manages the object types it defines; verify
   the plan does not target dbt/Cortex objects before deploying to a live db.

## Templating

`manifest.yml` resolves variables `defaults < configuration < runtime --variable`.
`{{ database }}` is `CLAIMS_DEV` (DEV) / `CLAIMS_PROD` (PROD); warehouse sizes and
`auto_suspend` also vary by target. Never put secrets in templating variables.
