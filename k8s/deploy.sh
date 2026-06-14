#!/usr/bin/env bash
# =============================================================================
# Deploy the claims Airflow + Cosmos dbt pipeline to a LOCAL Kubernetes cluster
# (Docker Desktop / kind / minikube) via the official Apache Airflow Helm chart.
#
#   ./k8s/deploy.sh
#
# Prereqs: docker, kubectl (context pointed at your local cluster), helm.
# Create k8s/snowflake-connection.secret.yaml first (from the .example).
# Data is SYNTHETIC -- not real CMS/Medicare/Medicaid/PHI.
# =============================================================================
set -euo pipefail

IMAGE="${IMAGE:-claims-airflow:local}"
NAMESPACE="${NAMESPACE:-airflow}"
RELEASE="${RELEASE:-airflow}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo ">> [1/5] build image (context = repo root)"
docker build -f "$ROOT/k8s/Dockerfile" -t "$IMAGE" "$ROOT"

echo ">> [2/5] load image into the local cluster"
CTX="$(kubectl config current-context)"
if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -q .; then
  kind load docker-image "$IMAGE"
elif command -v minikube >/dev/null 2>&1 && [[ "$CTX" == *minikube* ]]; then
  minikube image load "$IMAGE"
else
  echo "   (Docker Desktop / shared daemon assumed -- no image load needed; context=$CTX)"
fi

echo ">> [3/5] namespace + Snowflake connection secret"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
if [ -f "$ROOT/k8s/snowflake-connection.secret.yaml" ]; then
  kubectl apply -n "$NAMESPACE" -f "$ROOT/k8s/snowflake-connection.secret.yaml"
else
  echo "!! Missing k8s/snowflake-connection.secret.yaml"
  echo "   cp k8s/snowflake-connection.secret.example.yaml k8s/snowflake-connection.secret.yaml"
  echo "   # edit credentials, then re-run."
  exit 1
fi

echo ">> [4/5] helm install/upgrade"
helm repo add apache-airflow https://airflow.apache.org >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install "$RELEASE" apache-airflow/airflow \
  --namespace "$NAMESPACE" \
  -f "$ROOT/k8s/values.yaml" \
  --set images.airflow.repository="${IMAGE%:*}" \
  --set images.airflow.tag="${IMAGE##*:}" \
  --wait --timeout 10m

echo ">> [5/5] done. Open the UI with a port-forward:"
echo "   kubectl port-forward -n $NAMESPACE svc/${RELEASE}-webserver 8080:8080"
echo "   http://localhost:8080  (admin / admin) -> trigger the 'claims_dbt_cosmos' DAG"
