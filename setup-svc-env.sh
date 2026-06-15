#!/bin/bash
# Prepare the cluster environment for marketing-assistant.
# Run this BEFORE deploy.sh or kdeploy.sh.
#
# What it does (all imperative, cannot be replaced by GitOps):
#   1. Create namespaces
#   2. Create MLflow experiment
#   3. Configure Keycloak SSO (client, users, roles)
set -uo pipefail

NAMESPACE="${NAMESPACE:-marketing}"
KC_NAMESPACE="${KC_NAMESPACE:-keycloak-sso}"
KC_REALM="${KC_REALM:-marketing}"
MLFLOW_NS="${MLFLOW_NS:-mlflow}"
DOMAIN="${DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"

echo "=== Marketing-Assistant Environment Setup ==="
echo "Namespace:      $NAMESPACE"
echo "Cluster domain: $DOMAIN"
echo ""

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo "[0/3] Pre-flight checks..."

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi
if [ -z "$DOMAIN" ]; then
  echo "ERROR: Could not detect cluster domain. Set DOMAIN env var manually."
  exit 1
fi
echo "  OK"

# ---------------------------------------------------------------------------
# 1. Namespaces
# ---------------------------------------------------------------------------
echo "[1/3] Creating namespaces..."

oc get namespace "$NAMESPACE" &>/dev/null || oc new-project "$NAMESPACE" --display-name="Marketing Assistant" 2>/dev/null || \
  oc create namespace "$NAMESPACE" 2>/dev/null

for ENV_NS in "${NAMESPACE}-dev" "${NAMESPACE}-prod"; do
  oc get namespace "$ENV_NS" &>/dev/null || oc new-project "$ENV_NS" --display-name="Marketing Assistant (${ENV_NS##*-})" 2>/dev/null || \
    oc create namespace "$ENV_NS" 2>/dev/null
  echo "  Namespace $ENV_NS: OK"
done

# ---------------------------------------------------------------------------
# 2. MLflow experiment
# ---------------------------------------------------------------------------
echo "[2/3] Creating MLflow experiment..."

POSTGRES_POD=$(oc get pods -n "$MLFLOW_NS" -l app=mlflow-postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
DB_USER=$(oc get secret mlflow-postgresql-secret -n "$MLFLOW_NS" -o go-template='{{.data.database-user | base64decode}}' 2>/dev/null || echo "user")
DB_NAME=$(oc get secret mlflow-postgresql-secret -n "$MLFLOW_NS" -o go-template='{{.data.database-name | base64decode}}' 2>/dev/null || echo "db")
if [ -n "$POSTGRES_POD" ]; then
  oc exec "$POSTGRES_POD" -n "$MLFLOW_NS" -- psql -U "$DB_USER" -d "$DB_NAME" -c "
    INSERT INTO experiments (experiment_id, name, artifact_location, lifecycle_stage, creation_time, last_update_time)
    VALUES (1, 'marketing-assistant', '/mlflow/artifacts/1', 'active',
            EXTRACT(EPOCH FROM NOW())::bigint * 1000, EXTRACT(EPOCH FROM NOW())::bigint * 1000)
    ON CONFLICT (experiment_id) DO UPDATE SET lifecycle_stage = 'active';
  " 2>/dev/null && echo "  done" || echo "  skipped (MLflow DB not ready)"
else
  echo "  skipped (mlflow-postgresql not found in $MLFLOW_NS)"
fi

# ---------------------------------------------------------------------------
# 3. Keycloak SSO
# ---------------------------------------------------------------------------
echo "[3/3] Configuring Keycloak SSO..."

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
  echo "  Keycloak not found, skipping SSO configuration."
else
  KC_TOKEN=$(curl -sk -X POST "https://${KC_ROUTE}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KC_ADMIN_USER}" \
    -d "password=${KC_ADMIN_PASS}" \
    -d "grant_type=password" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

  if [ -z "$KC_TOKEN" ]; then
    echo "  WARNING: Could not obtain Keycloak token, skipping SSO configuration."
  else
    KC_REALM_API="https://${KC_ROUTE}/admin/realms/${KC_REALM}"
    FRONTEND_HOST=$(oc get route frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    FRONTEND_HOST=${FRONTEND_HOST:-"frontend-${NAMESPACE}.${DOMAIN}"}

    echo "  Creating 'marketing-ui' client..."
    curl -sk -X POST "${KC_REALM_API}/clients" \
      -H "Authorization: Bearer ${KC_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"clientId\": \"marketing-ui\",
        \"name\": \"Marketing Assistant Dashboard\",
        \"enabled\": true,
        \"publicClient\": true,
        \"standardFlowEnabled\": true,
        \"directAccessGrantsEnabled\": false,
        \"rootUrl\": \"https://${FRONTEND_HOST}\",
        \"redirectUris\": [\"https://${FRONTEND_HOST}/*\"],
        \"webOrigins\": [\"https://${FRONTEND_HOST}\"],
        \"attributes\": { \"pkce.code.challenge.method\": \"S256\" }
      }" 2>/dev/null > /dev/null
    echo "    done"

    echo "  Creating demo users..."
    for KC_USER_DATA in "alice:alice:Alice:Chen" "bob:bob:Bob:Santos"; do
      KC_UNAME=$(echo "$KC_USER_DATA" | cut -d: -f1)
      KC_UPASS=$(echo "$KC_USER_DATA" | cut -d: -f2)
      KC_FIRST=$(echo "$KC_USER_DATA" | cut -d: -f3)
      KC_LAST=$(echo "$KC_USER_DATA" | cut -d: -f4)

      curl -sk -X POST "${KC_REALM_API}/users" \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
          \"username\":\"${KC_UNAME}\",\"enabled\":true,
          \"firstName\":\"${KC_FIRST}\",\"lastName\":\"${KC_LAST}\",
          \"email\":\"${KC_UNAME}@example.com\",\"emailVerified\":true,
          \"credentials\":[{\"type\":\"password\",\"value\":\"${KC_UPASS}\",\"temporary\":false}]
        }" 2>/dev/null > /dev/null

      KC_UID=$(curl -sk -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KC_REALM_API}/users?username=${KC_UNAME}&exact=true" 2>/dev/null | \
        python3 -c "import sys,json; u=json.load(sys.stdin); print(u[0]['id'] if u else '')" 2>/dev/null || echo "")
      if [ -n "$KC_UID" ]; then
        curl -sk -X PUT "${KC_REALM_API}/users/${KC_UID}/reset-password" \
          -H "Authorization: Bearer ${KC_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"type\":\"password\",\"value\":\"${KC_UPASS}\",\"temporary\":false}" 2>/dev/null > /dev/null
      fi
      echo "    ${KC_UNAME} / ${KC_UPASS}"
    done

    echo "  Creating realm roles..."
    curl -sk -X POST "${KC_REALM_API}/roles" \
      -H "Authorization: Bearer ${KC_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"name":"platinum-access","description":"Access to platinum-tier customer data"}' 2>/dev/null > /dev/null
    echo "    platinum-access"

    echo "  Assigning roles..."
    PLAT_ROLE=$(curl -sk -H "Authorization: Bearer ${KC_TOKEN}" "${KC_REALM_API}/roles/platinum-access" 2>/dev/null)
    ALICE_ID=$(curl -sk -H "Authorization: Bearer ${KC_TOKEN}" \
      "${KC_REALM_API}/users?username=alice&exact=true" 2>/dev/null | \
      python3 -c "import sys,json; u=json.load(sys.stdin); print(u[0]['id'] if u else '')" 2>/dev/null || echo "")
    if [ -n "$ALICE_ID" ] && [ -n "$PLAT_ROLE" ] && [ "$PLAT_ROLE" != "null" ]; then
      curl -sk -X POST "${KC_REALM_API}/users/${ALICE_ID}/role-mappings/realm" \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "[${PLAT_ROLE}]" 2>/dev/null > /dev/null
      echo "    alice: platinum-access"
    fi
    echo "    (bob does NOT have platinum-access)"

    echo "  Patching frontend-keycloak-config..."
    oc create configmap frontend-keycloak-config -n "$NAMESPACE" \
      --from-literal="keycloak-config.js=window.__KEYCLOAK_URL__ = \"https://${KC_ROUTE}\";
window.__KEYCLOAK_REALM__ = \"${KC_REALM}\";
window.__KEYCLOAK_CLIENT_ID__ = \"marketing-ui\";" \
      --dry-run=client -o yaml | oc apply -f - -n "$NAMESPACE" 2>/dev/null
    echo "    done"
  fi
fi

echo ""
echo "=== Environment setup complete ==="
echo "Next: run ./deploy.sh or ./kdeploy.sh to deploy services."
