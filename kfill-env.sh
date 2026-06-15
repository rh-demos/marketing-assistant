#!/usr/bin/env bash
# Populate Kustomize secret .env files from the cluster.
#
# Reads model SA tokens from the models namespace and writes them into
# the Kustomize overlay secrets directory. The .env files are gitignored.
#
# Placeholder replacement (CLUSTER_DOMAIN, KC_URL) is handled at deploy
# time by kdeploy.sh — this script does NOT modify kustomization.yaml.
set -uo pipefail

NAMESPACE="${NAMESPACE:-marketing}"
MODEL_NS="${MODEL_NS:-models}"
KC_NAMESPACE="${KC_NAMESPACE:-keycloak-sso}"
OVERLAY="${1:-demo}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/kustomize/overlays/$OVERLAY"
SECRETS_DIR="$OVERLAY_DIR/secrets"

echo "=== Fill Kustomize Secrets (overlay: $OVERLAY) ==="
echo "App namespace:   $NAMESPACE"
echo "Model namespace: $MODEL_NS"
echo ""

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

mkdir -p "$SECRETS_DIR"

# ---------------------------------------------------------------------------
# Gather model tokens
# ---------------------------------------------------------------------------
echo "Gathering model tokens..."

get_token() {
  oc get secret "${1}-sa" -n "$MODEL_NS" \
    -o go-template='{{.data.token | base64decode}}' 2>/dev/null
}

SERVICE_MAP="imagegen-mcp:flux2-klein-4b creative-producer:qwen3-coder-30b customer-analyst:qwen3-32b-fp8-dynamic policy-guardian:qwen3-32b-fp8-dynamic delivery-manager:qwen3-32b-fp8-dynamic"

for entry in $SERVICE_MAP; do
  svc="${entry%%:*}"
  model="${entry#*:}"
  token=$(get_token "$model")
  if [ -z "$token" ]; then
    echo "  WARNING: Token not found for $model ($svc)"
    echo "MODEL_API_KEY=" > "$SECRETS_DIR/$svc.env"
  else
    echo "  $svc ($model): $(echo "$token" | head -c 30)..."
    echo "MODEL_API_KEY=$token" > "$SECRETS_DIR/$svc.env"
  fi
done

echo ""
echo "=== Done ==="
echo "Secrets written to: $SECRETS_DIR/"
echo "Next: ./setup-svc-env.sh && ./kdeploy.sh $OVERLAY"
