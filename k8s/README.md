# Deploy the Airflow + Cosmos dbt pipeline to local Kubernetes (Helm)

> Synthetic data — not real CMS/Medicare/Medicaid/PHI.

Deploys the same dbt pipeline as [`airflow/`](../airflow), but on a **local
Kubernetes cluster** using the official **Apache Airflow Helm chart** with the
**KubernetesExecutor** — each dbt task (via Cosmos) runs in its own pod.

```
k8s/
  Dockerfile                              # bakes DAGs + dbt project + Cosmos + dbt venv (context = repo root)
  values.yaml                             # Airflow Helm chart values (KubernetesExecutor, our image, secret)
  snowflake-connection.secret.example.yaml# Snowflake Airflow connection Secret template
  deploy.sh                               # build -> load -> secret -> helm upgrade
```

## Prerequisites

- A local Kubernetes cluster: **Docker Desktop Kubernetes**, **kind**, or **minikube**.
- `kubectl` (context pointed at that cluster), `helm` v3, and `docker`.
- Snowflake platform objects already provisioned (roles, warehouses, `CLAIMS_DEV`,
  schemas, control/audit/bronze tables) — via [`dcm/`](../dcm) or `snowflake/setup/`.

## Deploy (one command)

```bash
# 1) create the connection secret from the template and fill in credentials
cp k8s/snowflake-connection.secret.example.yaml k8s/snowflake-connection.secret.yaml
$EDITOR k8s/snowflake-connection.secret.yaml         # set account/user/password/role

# 2) build image -> load into cluster -> create secret -> helm install
./k8s/deploy.sh

# 3) open the UI
kubectl port-forward -n airflow svc/airflow-webserver 8080:8080
# http://localhost:8080  (admin / admin)  ->  trigger the `claims_dbt_cosmos` DAG
```

`make k8s-deploy` and `make k8s-forward` wrap steps 2–3.

## What `deploy.sh` does

1. **Builds** `claims-airflow:local` from `k8s/Dockerfile` (context = repo root) —
   the image bakes the DAGs (`airflow/dags`) and the dbt project (`dbt/`) plus
   Cosmos and an isolated dbt-snowflake venv. A repo-root `.dockerignore` keeps
   `target/`, `dbt_packages/`, `.venv`, secrets, and generated data out.
2. **Loads** the image into the cluster (`kind load` / `minikube image load`, or
   nothing for Docker Desktop's shared daemon).
3. **Creates** the `airflow` namespace and applies the Snowflake connection
   **Secret** (`claims-snowflake-conn`), injected into every pod as
   `AIRFLOW_CONN_SNOWFLAKE_CLAIMS` (`values.yaml` → `extraEnvFrom`).
4. **`helm upgrade --install`** the `apache-airflow/airflow` chart with
   `values.yaml` (KubernetesExecutor, our image, bundled Postgres metadata DB).

## Manual Helm (if you prefer)

```bash
docker build -f k8s/Dockerfile -t claims-airflow:local .
kind load docker-image claims-airflow:local            # or minikube image load ...
kubectl create namespace airflow
kubectl apply -n airflow -f k8s/snowflake-connection.secret.yaml
helm repo add apache-airflow https://airflow.apache.org && helm repo update
helm upgrade --install airflow apache-airflow/airflow -n airflow -f k8s/values.yaml --wait
```

## Notes & hardening

- **KubernetesExecutor:** every Airflow task is a pod using `claims-airflow:local`
  (dbt baked in); Cosmos runs dbt locally inside each task pod.
- **Cosmos render mode:** `LoadMode.DBT_LS` runs `dbt ls` at parse time in the
  scheduler/dag-processor pod, so Snowflake must be reachable from the cluster.
  For production, switch the DAG to `LoadMode.DBT_MANIFEST` against a committed
  `manifest.json` to avoid invoking dbt on every scheduler heartbeat.
- **Image distribution:** for a real cluster, push `claims-airflow` to a registry
  and set `images.airflow.repository`/`tag` + `pullPolicy: Always` instead of
  loading into a local node.
- **Metadata DB:** the chart's bundled Postgres is fine for local; use an
  external managed Postgres in production.
- **Secrets:** `k8s/snowflake-connection.secret.yaml` is git-ignored. For real
  clusters use a sealed-secret / external-secrets operator rather than a plain
  Secret, and prefer Snowflake key-pair auth.
- **Teardown:** `helm uninstall airflow -n airflow && kubectl delete namespace airflow`.
