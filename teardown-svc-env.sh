#!/bin/bash
# Remove cluster environment created by setup-svc-env.sh.
# Run AFTER undeploy.sh (or kundeploy.sh).
#
# What it removes (all imperative, cannot be handled by GitOps):
#   1. Keycloak SSO resources (client, users, roles)
#   2. Namespaces (marketing, marketing-dev, marketing-prod)
set -uo pipefail

NAMESPACE="${NAMESPACE:-marketing}"
KC_NAMESPACE="${KC_NAMESPACE:-keycloak-sso}"
KC_REALM="${KC_REALM:-marketing}"

echo "=== Marketing-Assistant Environment Teardown ==="
echo "Namespace: $NAMESPACE"
echo ""

read -p "This will delete Keycloak resources and namespaces. Continue? [y/N] " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Keycloak cleanup
# ---------------------------------------------------------------------------
echo "[1/2] Cleaning up Keycloak..."

KC_ROUTE=$(oc get route keycloak -n "$KC_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
KC_ADMIN_USER=""
KC_ADMIN_PASS=""
if oc get secret keycloak-admin -n "$KC_NAMESPACE" &>/dev/null; then
  KC_ADMIN_USER=$(oc get secret keycloak-admin -n "$KC_NAMESPACE" -o go-template='{{.data.username | base64decode}}' 2>/dev/null)
  KC_ADMIN_PASS=$(oc get secret keycloak-admin -n "$KC_NAMESPACE" -o go-template='{{.data.password | base64decode}}' 2>/dev/null)
fi
if [ -z "$KC_ADMIN_USER" ] && oc get secret keycloak-initial-admin -n "$KC_NAMESPACE" &>/dev/null; then
  KC_ADMIN_USER=$(oc get secret keycloak-initial-admin -n "$KC_NAMESPACE" -o go-template='{{.data.username | base64decode}}' 2>/dev/null)
  KC_ADMIN_PASS=$(oc get secret keycloak-initial-admin -n "$KC_NAMESPACE" -o go-template='{{.data.password | base64decode}}' 2>/dev/null)
fi

if [ -z "$KC_ROUTE" ] || [ -z "$KC_ADMIN_USER" ]; then
  echo "  Keycloak not found, skipping."
else
  KC_TOKEN=$(curl -sk -X POST "https://${KC_ROUTE}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KC_ADMIN_USER}" \
    -d "password=${KC_ADMIN_PASS}" \
    -d "grant_type=password" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

  if [ -z "$KC_TOKEN" ]; then
    echo "  WARNING: Could not obtain Keycloak token, skipping cleanup."
  else
    KC_REALM_API="https://${KC_ROUTE}/admin/realms/${KC_REALM}"

    CLIENT_ID=$(curl -sk -H "Authorization: Bearer ${KC_TOKEN}" \
      "${KC_REALM_API}/clients?clientId=marketing-ui" 2>/dev/null | \
      python3 -c "import sys,json; c=json.load(sys.stdin); print(c[0]['id'] if c else '')" 2>/dev/null || echo "")
    if [ -n "$CLIENT_ID" ]; then
      curl -sk -X DELETE "${KC_REALM_API}/clients/${CLIENT_ID}" \
        -H "Authorization: Bearer ${KC_TOKEN}" 2>/dev/null
      echo "  Deleted client: marketing-ui"
    fi

    for DEL_USER in alice bob; do
      DEL_UID=$(curl -sk -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KC_REALM_API}/users?username=${DEL_USER}&exact=true" 2>/dev/null | \
        python3 -c "import sys,json; u=json.load(sys.stdin); print(u[0]['id'] if u else '')" 2>/dev/null || echo "")
      if [ -n "$DEL_UID" ]; then
        curl -sk -X DELETE "${KC_REALM_API}/users/${DEL_UID}" \
          -H "Authorization: Bearer ${KC_TOKEN}" 2>/dev/null
        echo "  Deleted user: ${DEL_USER}"
      fi
    done

    for DEL_ROLE in platinum-access; do
      curl -sk -X DELETE "${KC_REALM_API}/roles/${DEL_ROLE}" \
        -H "Authorization: Bearer ${KC_TOKEN}" 2>/dev/null && \
        echo "  Deleted role: ${DEL_ROLE}" || true
    done
  fi
fi

# ---------------------------------------------------------------------------
# 2. Delete namespaces
# ---------------------------------------------------------------------------
echo "[2/2] Deleting namespaces..."
for DEL_NS in "$NAMESPACE" "${NAMESPACE}-dev" "${NAMESPACE}-prod"; do
  oc delete namespace "$DEL_NS" --ignore-not-found --timeout=120s 2>/dev/null || true
  echo "  Deleted namespace: $DEL_NS"
done

echo ""
echo "=== Teardown complete ==="
