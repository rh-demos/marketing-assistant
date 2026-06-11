#!/bin/bash
# Deploy Keycloak (PostgreSQL + Keycloak Server) to OpenShift
set -uo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
KC_REALM="${KC_REALM:-marketing}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Keycloak Deployment ==="
echo "Namespace: $NAMESPACE"
echo "Realm:     $KC_REALM"
echo ""

# ---------------------------------------------------------------------------
# Phase 0: Pre-flight checks
# ---------------------------------------------------------------------------
echo "[0/3] Pre-flight checks..."

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
echo "[1/3] Deploying PostgreSQL..."
oc apply -f "$SCRIPT_DIR/01-keycloak-postgres.yaml" -n "$NAMESPACE"
oc wait --for=condition=available --timeout=120s deployment/keycloak-postgresql-deployment -n "$NAMESPACE" || true
echo "  PostgreSQL deployed"

# ---------------------------------------------------------------------------
# Phase 2: Deploy Keycloak Server
# ---------------------------------------------------------------------------
echo "[2/3] Deploying Keycloak Server..."

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "apps.example.com")
KC_HOSTNAME="https://keycloak-${NAMESPACE}.${CLUSTER_DOMAIN}"

sed "s|KC_HOSTNAME_PLACEHOLDER|${KC_HOSTNAME}|g" \
  "$SCRIPT_DIR/02-keycloak-server.yaml" | oc apply -f - -n "$NAMESPACE"

oc wait --for=condition=available --timeout=300s deployment/keycloak -n "$NAMESPACE" || true
echo "  Keycloak Server deployed"

# ---------------------------------------------------------------------------
# Phase 3: Create realm
# ---------------------------------------------------------------------------
echo "[3/3] Creating realm '$KC_REALM'..."

KC_ROUTE=$(oc get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
KC_ADMIN_USER=$(oc get secret keycloak-admin -n "$NAMESPACE" -o go-template='{{.data.username | base64decode}}' 2>/dev/null)
KC_ADMIN_PASS=$(oc get secret keycloak-admin -n "$NAMESPACE" -o go-template='{{.data.password | base64decode}}' 2>/dev/null)

if [ -z "$KC_ROUTE" ] || [ -z "$KC_ADMIN_USER" ]; then
  echo "  Skipped (route or admin secret not ready — create realm manually)"
else
  KC_TOKEN=$(curl -sk -X POST "https://${KC_ROUTE}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KC_ADMIN_USER}" \
    -d "password=${KC_ADMIN_PASS}" \
    -d "grant_type=password" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

  if [ -z "$KC_TOKEN" ]; then
    echo "  WARNING: Could not obtain admin token. Keycloak may still be starting."
    echo "  Re-run this script or create the realm manually."
  else
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${KC_ROUTE}/admin/realms" \
      -H "Authorization: Bearer ${KC_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"realm\": \"${KC_REALM}\", \"enabled\": true}" 2>/dev/null)
    if [ "$HTTP_CODE" = "201" ]; then
      echo "  Realm '$KC_REALM' created"
    elif [ "$HTTP_CODE" = "409" ]; then
      echo "  Realm '$KC_REALM' already exists"
    else
      echo "  WARNING: Realm creation returned HTTP $HTTP_CODE (may need retry)"
    fi
  fi
fi

echo ""
echo "=== Keycloak deployment complete ==="
echo ""
echo "Routes:"
oc get routes -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{printf "  %-30s https://%s\n", $1, $2}'
echo ""
echo "Admin credentials:"
echo "  oc get secret keycloak-admin -n $NAMESPACE -o go-template='{{.data.username | base64decode}}'"
echo "  oc get secret keycloak-admin -n $NAMESPACE -o go-template='{{.data.password | base64decode}}'"
echo ""
echo "Usage: NAMESPACE=<ns> KC_REALM=<realm> $0"
