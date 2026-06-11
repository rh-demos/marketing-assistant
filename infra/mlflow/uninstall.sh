#!/bin/bash
# Uninstall MLflow from OpenShift (PVCs are preserved by default)
set -uo pipefail

NAMESPACE="${NAMESPACE:-mlflow}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== MLflow Uninstall ==="
echo "Namespace: $NAMESPACE"
echo ""
echo "This will remove OTEL Collector, MLflow Server, MinIO, and PostgreSQL."
echo "PVCs are preserved to avoid data loss."
echo ""

read -p "Continue? [y/N] " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo "[1/4] Removing OTEL Collector..."
oc delete -f "$SCRIPT_DIR/04-otel-collector.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "[2/4] Removing MLflow Server..."
oc delete -f "$SCRIPT_DIR/03-mlflow-server.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "[3/4] Removing MinIO..."
oc delete -f "$SCRIPT_DIR/02-mlflow-minio.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "[4/4] Removing PostgreSQL..."
oc delete -f "$SCRIPT_DIR/01-mlflow-postgres.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo ""
echo "PVCs preserved:"
oc get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | head -10
echo ""
echo "To also delete PVCs (and all data), run:"
echo "  oc delete pvc mlflow-postgresql-pvc mlflow-minio-pvc -n $NAMESPACE"
echo ""
echo "=== MLflow uninstall complete ==="
echo ""
echo "Usage: NAMESPACE=<ns> $0"
