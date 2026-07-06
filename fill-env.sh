#!/usr/bin/env bash
# Fill <TODO> placeholders in k8s.yaml templates to produce .k8s.yaml files.
#
# Reads model tokens from the models namespace and cluster domain from
# OpenShift ingress config, then substitutes into each service's k8s.yaml
# and k8s-knative.yaml (when present).
set -uo pipefail

NAMESPACE="${NAMESPACE:-marketing}"
MODEL_NS="${MODEL_NS:-models}"
KC_NAMESPACE="${KC_NAMESPACE:-keycloak-sso}"
KC_REALM="${KC_REALM:-marketing}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Fill Environment Config ==="
echo "App namespace:   $NAMESPACE"
echo "Model namespace: $MODEL_NS"
echo ""

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Gather values
# ---------------------------------------------------------------------------
echo "Gathering cluster info..."

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
if [ -z "$CLUSTER_DOMAIN" ]; then
  echo "ERROR: Could not detect cluster domain."
  exit 1
fi
echo "  CLUSTER_DOMAIN: $CLUSTER_DOMAIN"

KC_ROUTE=$(oc get route keycloak -n "$KC_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
KC_ISSUER="https://${KC_ROUTE}/realms/${KC_REALM}"
echo "  KC_ISSUER: $KC_ISSUER"

echo "Gathering model tokens..."

get_token() {
  oc get secret "${1}-sa" -n "$MODEL_NS" \
    -o go-template='{{.data.token | base64decode}}' 2>/dev/null
}

TOKEN_QWEN3_32B=$(get_token qwen3-32b-fp8-dynamic)
TOKEN_FLUX2=$(get_token flux2-klein-4b)
TOKEN_QWEN3_CODER=$(get_token qwen3-coder-30b)

for name_token in "qwen3-32b-fp8-dynamic:$TOKEN_QWEN3_32B" "flux2-klein-4b:$TOKEN_FLUX2" "qwen3-coder-30b:$TOKEN_QWEN3_CODER"; do
  name="${name_token%%:*}"
  token="${name_token#*:}"
  if [ -z "$token" ]; then
    echo "  WARNING: Token not found for $name"
  else
    echo "  $name: $(echo "$token" | head -c 30)..."
  fi
done

# ---------------------------------------------------------------------------
# Resolve token for a service
# ---------------------------------------------------------------------------
token_for_service() {
  case "$1" in
    creative-producer)  echo "$TOKEN_QWEN3_CODER" ;;
    customer-analyst)   echo "$TOKEN_QWEN3_32B" ;;
    policy-guardian)    echo "$TOKEN_QWEN3_32B" ;;
    delivery-manager)   echo "$TOKEN_QWEN3_32B" ;;
    imagegen-mcp)       echo "$TOKEN_FLUX2" ;;
    *)                  echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# Generate filled manifests from k8s.yaml / k8s-knative.yaml templates
# ---------------------------------------------------------------------------
fill_manifest() {
  local src="$1"
  local dst="$2"
  local svc="$3"

  if ! grep -q '<TODO' "$src" 2>/dev/null; then
    cp "$src" "$dst"
    echo "  $svc ($(basename "$src")): copied (no TODOs)"
    return
  fi

  local token
  token=$(token_for_service "$svc")

  sed \
    -e "s|CLUSTER_DOMAIN: \"<TODO>\"|CLUSTER_DOMAIN: \"$CLUSTER_DOMAIN\"|g" \
    -e "s|namespace: \"<TODO>\"|namespace: \"$NAMESPACE\"|g" \
    -e "s|MODEL_API_KEY: \"<TODO>\"|MODEL_API_KEY: \"$token\"|g" \
    -e "s|<TODO_KC_ISSUER>|$KC_ISSUER|g" \
    -e "s|<TODO_NAMESPACE>|$NAMESPACE|g" \
    "$src" > "$dst"

  echo "  $svc ($(basename "$src")): generated"
}

echo ""
echo "Generating filled manifests..."

for svc_dir in "$SCRIPT_DIR"/*/; do
  svc=$(basename "$svc_dir")

  if [ -f "$svc_dir/k8s.yaml" ]; then
    fill_manifest "$svc_dir/k8s.yaml" "$svc_dir/.k8s.yaml" "$svc"
  fi

  if [ -f "$svc_dir/k8s-knative.yaml" ]; then
    fill_manifest "$svc_dir/k8s-knative.yaml" "$svc_dir/.k8s-knative.yaml" "$svc"
  fi
done

echo ""
echo "=== Done ==="
echo "Generated manifests are ready for deployment with deploy.sh or service-specific scripts."
