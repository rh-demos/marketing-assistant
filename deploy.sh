#!/bin/bash
# Deploy marketing-assistant services to OpenShift.
# Run setup-svc-env.sh first to prepare the cluster environment.
set -uo pipefail

NAMESPACE="${NAMESPACE:-marketing}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Marketing-Assistant Deploy ==="
echo "Namespace: $NAMESPACE"
echo ""

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Create vertical-config ConfigMap
# ---------------------------------------------------------------------------
echo "[1/3] Creating vertical-config ConfigMap..."
oc create configmap vertical-config \
  --from-file="$SCRIPT_DIR/config-service/app/verticals/" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f - -n "$NAMESPACE" 2>/dev/null

# ---------------------------------------------------------------------------
# Deploy all services
# ---------------------------------------------------------------------------
echo "[2/3] Deploying services..."

SERVICES=(
  mongodb
  config-service
  event-hub
  mongodb-mcp
  imagegen-mcp
  campaign-director
  creative-producer
  customer-analyst
  policy-guardian
  delivery-manager
  campaign-api
  frontend
)

for svc in "${SERVICES[@]}"; do
  if [ -f "$SCRIPT_DIR/$svc/.k8s.yaml" ]; then
    echo "  Applying $svc (.k8s.yaml)..."
    oc apply -f "$SCRIPT_DIR/$svc/.k8s.yaml" -n "$NAMESPACE" 2>/dev/null || true
  elif [ -f "$SCRIPT_DIR/$svc/k8s.yaml" ]; then
    echo "  Applying $svc (k8s.yaml)..."
    oc apply -f "$SCRIPT_DIR/$svc/k8s.yaml" -n "$NAMESPACE" 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo "[3/3] Verifying deployment..."
echo ""
echo "Pods in $NAMESPACE:"
oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | head -20
echo ""

FRONTEND_ROUTE=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
echo "=== Deployment complete ==="
echo ""
echo "Routes:"
oc get routes -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{printf "  %-15s https://%s\n", $1, $2}'
echo ""
if [ -n "$FRONTEND_ROUTE" ]; then
  echo "Frontend: https://${FRONTEND_ROUTE}"
fi
