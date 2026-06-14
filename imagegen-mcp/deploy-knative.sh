#!/usr/bin/env bash
# Switch imagegen-mcp from Deployment mode to Knative Service mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-marketing}"
MANIFEST="$SCRIPT_DIR/.k8s-knative.yaml"

echo "=== Deploy imagegen-mcp (Knative mode) ==="
echo "Namespace: $NAMESPACE"
echo ""

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

echo "[1/5] Generating manifests..."
"$ROOT_DIR/fill-env.sh"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: Missing $MANIFEST — ensure k8s-knative.yaml exists and fill-env.sh ran successfully."
  exit 1
fi

echo "[2/5] Removing Deployment mode resources..."
oc delete deployment,service imagegen-mcp -n "$NAMESPACE" --ignore-not-found

echo "[3/5] Applying Knative manifest..."
oc apply -f "$MANIFEST" -n "$NAMESPACE"

echo "[4/5] Waiting for Knative Service to become Ready..."
oc wait --for=condition=Ready ksvc/imagegen-mcp -n "$NAMESPACE" --timeout=300s

# Knative routes by Host header; short names like "imagegen-mcp" return 404.
# Use the namespace-qualified cluster-local FQDN (port 80 via Knative Service).
IMAGEGEN_MCP_URL="http://imagegen-mcp.${NAMESPACE}.svc.cluster.local"

echo "[5/5] Updating imagegen consumers to use Knative cluster-local URL..."
for CM in creative-producer-config campaign-api-config; do
  oc patch configmap "$CM" -n "$NAMESPACE" --type merge \
    -p "{\"data\":{\"IMAGEGEN_MCP_URL\":\"${IMAGEGEN_MCP_URL}\"}}"
done
oc rollout restart deployment/creative-producer deployment/campaign-api -n "$NAMESPACE"
oc rollout status deployment/creative-producer -n "$NAMESPACE" --timeout=180s
oc rollout status deployment/campaign-api -n "$NAMESPACE" --timeout=180s

echo ""
echo "=== Knative deployment complete ==="
oc get ksvc imagegen-mcp -n "$NAMESPACE"
echo ""
echo "IMAGEGEN_MCP_URL (creative-producer, campaign-api): ${IMAGEGEN_MCP_URL}"
