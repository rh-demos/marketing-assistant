#!/bin/bash
# Uninstall Keycloak from OpenShift (PVCs are preserved by default)
set -uo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Keycloak Uninstall ==="
echo "Namespace: $NAMESPACE"
echo ""
echo "This will remove Keycloak Server and PostgreSQL."
echo "PVCs are preserved to avoid data loss."
echo ""

read -p "Continue? [y/N] " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo "[1/2] Removing Keycloak Server..."
oc delete -f "$SCRIPT_DIR/02-keycloak-server.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
oc delete secret keycloak-admin -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "[2/2] Removing PostgreSQL..."
oc delete -f "$SCRIPT_DIR/01-keycloak-postgres.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo ""
echo "PVCs preserved:"
oc get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | head -10
echo ""
echo "To also delete PVCs (and all data), run:"
echo "  oc delete pvc keycloak-postgresql-pvc -n $NAMESPACE"
echo ""
echo "=== Keycloak uninstall complete ==="
echo ""
echo "Usage: NAMESPACE=<ns> $0"
