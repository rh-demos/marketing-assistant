#!/usr/bin/env bash
# Revert imagegen-mcp from Knative Service mode back to Deployment mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-marketing}"
MANIFEST="$SCRIPT_DIR/.k8s.yaml"

echo "=== Revert imagegen-mcp to Deployment mode ==="
echo "Namespace: $NAMESPACE"
echo ""

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

echo "[1/5] Generating manifests..."
"$ROOT_DIR/fill-env.sh"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: Missing $MANIFEST — ensure k8s.yaml exists and fill-env.sh ran successfully."
  exit 1
fi

echo "[2/5] Removing Knative Service..."
oc delete ksvc imagegen-mcp -n "$NAMESPACE" --ignore-not-found

echo "[3/5] Waiting for Knative pods to terminate..."
oc wait --for=delete pod -n "$NAMESPACE" \
  -l serving.knative.dev/service=imagegen-mcp --timeout=120s 2>/dev/null || true

echo "[4/5] Applying Deployment manifest..."
oc apply -f "$MANIFEST" -n "$NAMESPACE"
oc rollout status deployment/imagegen-mcp -n "$NAMESPACE" --timeout=180s

echo "[5/5] Updating imagegen consumers to use Deployment cluster-local URL (port 8083)..."
for CM in creative-producer-config campaign-api-config; do
  oc patch configmap "$CM" -n "$NAMESPACE" --type merge \
    -p '{"data":{"IMAGEGEN_MCP_URL":"http://imagegen-mcp:8083"}}'
done
oc rollout restart deployment/creative-producer deployment/campaign-api -n "$NAMESPACE"
oc rollout status deployment/creative-producer -n "$NAMESPACE" --timeout=180s
oc rollout status deployment/campaign-api -n "$NAMESPACE" --timeout=180s

echo ""
echo "=== Revert complete ==="
oc get deployment,service imagegen-mcp -n "$NAMESPACE"
echo ""
echo "IMAGEGEN_MCP_URL (creative-producer, campaign-api): http://imagegen-mcp:8083"
