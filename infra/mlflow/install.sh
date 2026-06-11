#!/bin/bash
# Deploy MLflow (PostgreSQL + MinIO + MLflow Server + OTEL Collector) to OpenShift
set -uo pipefail

NAMESPACE="${NAMESPACE:-mlflow}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== MLflow Deployment ==="
echo "Namespace: $NAMESPACE"
echo ""

# ---------------------------------------------------------------------------
# Phase 0: Pre-flight checks
# ---------------------------------------------------------------------------
echo "[0/5] Pre-flight checks..."

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

oc get namespace "$NAMESPACE" &>/dev/null || oc new-project "$NAMESPACE" 2>/dev/null || \
  oc create namespace "$NAMESPACE" 2>/dev/null

echo "  Pre-flight OK"

# ---------------------------------------------------------------------------
# Phase 1: Deploy PostgreSQL
# ---------------------------------------------------------------------------
echo "[1/5] Deploying PostgreSQL..."
oc apply -f "$SCRIPT_DIR/01-mlflow-postgres.yaml" -n "$NAMESPACE"
oc wait --for=condition=available --timeout=120s deployment/mlflow-postgresql-deployment -n "$NAMESPACE" || true
echo "  PostgreSQL deployed"

# ---------------------------------------------------------------------------
# Phase 2: Deploy MinIO
# ---------------------------------------------------------------------------
echo "[2/5] Deploying MinIO..."
oc apply -f "$SCRIPT_DIR/02-mlflow-minio.yaml" -n "$NAMESPACE"
echo "  MinIO manifests applied (root-user Job + Deployment + bucket Job)"

# ---------------------------------------------------------------------------
# Phase 3: Deploy MLflow Server
# ---------------------------------------------------------------------------
echo "[3/5] Deploying MLflow Server..."

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "apps.example.com")
sed "s|value: \"apps.example.com\"|value: \"${CLUSTER_DOMAIN}\"|g" \
  "$SCRIPT_DIR/03-mlflow-server.yaml" | oc apply -f - -n "$NAMESPACE"

echo "  MLflow Server deployed"

# ---------------------------------------------------------------------------
# Phase 4: Deploy OpenTelemetry Collector
# ---------------------------------------------------------------------------
echo "[4/5] Deploying OpenTelemetry Collector..."
oc apply -f "$SCRIPT_DIR/04-otel-collector.yaml" -n "$NAMESPACE"
oc wait --for=condition=available --timeout=60s deployment/otel-collector -n "$NAMESPACE" || true
echo "  OTEL Collector deployed"

# ---------------------------------------------------------------------------
# Phase 5: MLflow trace-name trigger
# ---------------------------------------------------------------------------
# OTLP ingest doesn't set mlflow.traceName (fixed in MLflow v3.13+).
# Install a PostgreSQL trigger to populate it from root span name.
echo "[5/5] Installing trace-name trigger..."
oc wait --for=condition=Available deployment/mlflow-deployment -n "$NAMESPACE" --timeout=180s 2>/dev/null || true

POSTGRES_POD=$(oc get pods -n "$NAMESPACE" -l app=mlflow-postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
DB_USER=$(oc get secret mlflow-postgresql-secret -n "$NAMESPACE" -o go-template='{{.data.database-user | base64decode}}' 2>/dev/null || echo "user")
DB_NAME=$(oc get secret mlflow-postgresql-secret -n "$NAMESPACE" -o go-template='{{.data.database-name | base64decode}}' 2>/dev/null || echo "db")

if [ -n "$POSTGRES_POD" ]; then
  oc exec "$POSTGRES_POD" -n "$NAMESPACE" -- psql -U "$DB_USER" -d "$DB_NAME" -c "
    CREATE OR REPLACE FUNCTION set_trace_name_from_root_span()
    RETURNS TRIGGER AS \$\$
    BEGIN
        IF NEW.parent_span_id IS NULL THEN
            INSERT INTO trace_tags (request_id, key, value)
            VALUES (NEW.trace_id, 'mlflow.traceName', NEW.name)
            ON CONFLICT (request_id, key) DO UPDATE SET value = EXCLUDED.value;
        END IF;
        RETURN NEW;
    END;
    \$\$ LANGUAGE plpgsql;
    DO \$\$ BEGIN
        CREATE TRIGGER trg_set_trace_name
            AFTER INSERT ON spans
            FOR EACH ROW
            EXECUTE FUNCTION set_trace_name_from_root_span();
    EXCEPTION WHEN duplicate_object THEN NULL;
    END \$\$;
  " 2>/dev/null && echo "  Trigger installed" || echo "  Skipped (MLflow DB not ready yet — run again after MLflow starts)"
else
  echo "  Skipped (PostgreSQL pod not found)"
fi

echo ""
echo "=== MLflow deployment complete ==="
echo ""
echo "Routes:"
oc get routes -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{printf "  %-30s https://%s\n", $1, $2}'
echo ""
echo "OTEL Collector endpoint (for agents):"
echo "  http://otel-collector.${NAMESPACE}.svc.cluster.local:4318/v1/traces"
echo ""
echo "Usage: NAMESPACE=<ns> $0"
