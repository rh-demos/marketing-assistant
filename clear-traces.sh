#!/bin/bash
# Clear all tracing data from MLflow experiment
set -uo pipefail

MLFLOW_NS="${MLFLOW_NS:-mlflow}"
EXPERIMENT_ID="${EXPERIMENT_ID:-1}"

POSTGRES_POD=$(oc get pods -n "$MLFLOW_NS" -l app=mlflow-postgresql \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POSTGRES_POD" ]; then
  echo "ERROR: mlflow-postgresql pod not found in $MLFLOW_NS"
  exit 1
fi

DB_USER=$(oc get secret mlflow-postgresql-secret -n "$MLFLOW_NS" -o go-template='{{.data.database-user | base64decode}}' 2>/dev/null || echo "user")
DB_NAME=$(oc get secret mlflow-postgresql-secret -n "$MLFLOW_NS" -o go-template='{{.data.database-name | base64decode}}' 2>/dev/null || echo "db")

COUNT=$(oc exec "$POSTGRES_POD" -n "$MLFLOW_NS" -- \
  psql -U "$DB_USER" -d "$DB_NAME" -tAc \
  "SELECT count(*) FROM trace_info WHERE experiment_id = $EXPERIMENT_ID;" 2>/dev/null)

echo "Found $COUNT traces in experiment $EXPERIMENT_ID"

if [ "$COUNT" -eq 0 ]; then
  echo "Nothing to delete."
  exit 0
fi

read -p "Delete all $COUNT traces? [y/N] " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

oc exec "$POSTGRES_POD" -n "$MLFLOW_NS" -- \
  psql -U "$DB_USER" -d "$DB_NAME" -c \
  "DELETE FROM trace_info WHERE experiment_id = $EXPERIMENT_ID;"

echo "Done."
