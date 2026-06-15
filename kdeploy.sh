#!/bin/bash
# Deploy marketing-assistant to OpenShift using Kustomize.
# Run setup-svc-env.sh first to prepare the cluster environment.
#
# Usage:
#   ./kfill-env.sh [overlay]       # populate secrets from cluster
#   ./setup-svc-env.sh             # prepare namespaces, Keycloak, MLflow
#   ./kdeploy.sh   [overlay]       # deploy via kustomize
set -uo pipefail

OVERLAY="${1:-demo}"
NAMESPACE="${NAMESPACE:-marketing}"
KC_NAMESPACE="${KC_NAMESPACE:-keycloak-sso}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/kustomize/overlays/$OVERLAY"
KUST_FILE="$OVERLAY_DIR/kustomization.yaml"

echo "=== Marketing-Assistant Deploy (Kustomize) ==="
echo "Overlay:   $OVERLAY"
echo "Namespace: $NAMESPACE"
echo ""

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Pre-flight: check overlay and secrets
# ---------------------------------------------------------------------------
echo "[1/3] Pre-flight checks..."

if [ ! -f "$KUST_FILE" ]; then
  echo "ERROR: Overlay not found at $OVERLAY_DIR"
  exit 1
fi

MISSING_SECRETS=0
for svc in imagegen-mcp creative-producer customer-analyst policy-guardian delivery-manager; do
  if [ ! -f "$OVERLAY_DIR/secrets/$svc.env" ]; then
    echo "  WARNING: Missing $OVERLAY_DIR/secrets/$svc.env"
    MISSING_SECRETS=1
  fi
done
if [ "$MISSING_SECRETS" -eq 1 ]; then
  echo "  Run './kfill-env.sh $OVERLAY' first to generate secret files."
  exit 1
fi
echo "  OK"

# ---------------------------------------------------------------------------
# Replace placeholders in kustomization.yaml (auto-restore on exit)
# ---------------------------------------------------------------------------
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
KC_URL=$(oc get route keycloak -n "$KC_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
[ -n "$KC_URL" ] && KC_URL="https://$KC_URL"

cp "$KUST_FILE" "$KUST_FILE.bak"
trap 'mv "$KUST_FILE.bak" "$KUST_FILE"' EXIT

sed -i'' \
  -e "s|CLUSTER_DOMAIN_PLACEHOLDER|$CLUSTER_DOMAIN|g" \
  -e "s|KC_URL_PLACEHOLDER|$KC_URL|g" \
  "$KUST_FILE"

echo "  CLUSTER_DOMAIN: $CLUSTER_DOMAIN"
[ -n "$KC_URL" ] && echo "  KC_URL: $KC_URL"

# ---------------------------------------------------------------------------
# Apply Kustomize manifests
# ---------------------------------------------------------------------------
echo "[2/3] Applying Kustomize manifests (overlay: $OVERLAY)..."

oc kustomize --load-restrictor LoadRestrictionsNone "$OVERLAY_DIR" | oc apply -f - 2>&1 | grep -v "^$" | while read -r line; do
  echo "  $line"
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
