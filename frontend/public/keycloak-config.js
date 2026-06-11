// Runtime Keycloak configuration — overwritten by docker-entrypoint.sh at deploy time.
// When KEYCLOAK_URL is empty, auth is disabled and the app runs without login.
window.__KEYCLOAK_URL__ = "";
window.__KEYCLOAK_REALM__ = "marketing";
window.__KEYCLOAK_CLIENT_ID__ = "marketing-ui";
