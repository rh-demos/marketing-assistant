#!/bin/bash
# Remove marketing-assistant services from OpenShift.
# Run teardown-svc-env.sh after this to clean up Keycloak and namespaces.
set -uo pipefail

NAMESPACE="${NAMESPACE:-marketing}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Marketing-Assistant Undeploy ==="
echo "Namespace: $NAMESPACE"
echo ""

read -p "Continue? [y/N] " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Delete application resources
# ---------------------------------------------------------------------------
echo "[1/2] Removing application resources..."

SERVICES=(
  frontend
  campaign-api
  delivery-manager
  policy-guardian
  customer-analyst
  creative-producer
  campaign-director
  imagegen-mcp
  mongodb-mcp
  event-hub
  config-service
  mongodb
)

for svc in "${SERVICES[@]}"; do
  if [ -f "$SCRIPT_DIR/$svc/.k8s.yaml" ]; then
    echo "  Deleting $svc..."
    oc delete -f "$SCRIPT_DIR/$svc/.k8s.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  elif [ -f "$SCRIPT_DIR/$svc/k8s.yaml" ]; then
    echo "  Deleting $svc..."
    oc delete -f "$SCRIPT_DIR/$svc/k8s.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  fi
done

# Delete Knative resources (if Serverless was used)
echo "  Deleting Knative services..."
oc delete ksvc --all -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
oc delete ksvc --all -n "${NAMESPACE}-dev" --ignore-not-found 2>/dev/null || true
oc delete ksvc --all -n "${NAMESPACE}-prod" --ignore-not-found 2>/dev/null || true

# Delete vertical-config ConfigMap
echo "  Deleting vertical-config ConfigMap..."
oc delete configmap vertical-config -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo "[2/2] Verifying..."
echo ""
echo "Remaining pods in $NAMESPACE:"
oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | head -10 || echo "  (none)"
echo ""
echo "=== Undeploy complete ==="
echo "Next: run ./teardown-svc-env.sh to remove Keycloak resources and namespaces."
