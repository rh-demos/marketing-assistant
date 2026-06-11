# Infrastructure Setup

## Installation Order

### 1. OpenShift AI

Install GPU operators and OpenShift AI platform. See [openshift-ai.md](openshift-ai.md) for details.

```bash
# Prerequisites: NFD, NVIDIA GPU Operator, GPU nodes (L40S x3)
# Install operators: cert-manager, Authorino, Service Mesh 3, OpenShift AI 3.x
# Create DataScienceCluster (see openshift-ai.md)
```

### 2. Models

Deploy LLM models via KServe. Models auto-download from HuggingFace on first start, PVCs cache for persistence.

```bash
./models/install.sh                  # default namespace: models
# NAMESPACE=my-ns ./models/install.sh  # custom namespace
```

Models deployed:
- `qwen3-32b-fp8-dynamic` — RedHatAI/Qwen3-32B-FP8-dynamic (50Gi PVC)
- `flux2-klein-4b` — black-forest-labs/FLUX.2-klein-4B (40Gi PVC)
- `qwen3-coder-30b` — Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 (50Gi PVC)

### 3. Guardrails

Deploy TrustyAI guardrails (HAP detector, prompt injection detector, orchestrator).

```bash
./guardrails/install.sh              # default namespace: models
# NAMESPACE=my-ns ./guardrails/install.sh
```

### 4. MLflow + Observability

Deploy MLflow (PostgreSQL + MinIO + MLflow Server) and an OpenTelemetry Collector for agent trace collection.

```bash
./mlflow/install.sh                  # default namespace: mlflow
# NAMESPACE=my-ns ./mlflow/install.sh
```

Components deployed:
- **PostgreSQL** (pgvector) — MLflow backend store (20Gi PVC)
- **MinIO** — S3-compatible artifact storage (50Gi PVC)
- **MLflow v3.11.1** — tracking server with S3 artifact store
- **OpenTelemetry Collector** — receives OTLP traces from agents, forwards to MLflow

Agent OTEL endpoint: `http://otel-collector.mlflow.svc.cluster.local:4318/v1/traces`

### 5. Keycloak (SSO)

Deploy Keycloak server (PostgreSQL backend + Keycloak + Route) for SSO authentication.

```bash
./keycloak/install.sh                # default namespace: keycloak
# NAMESPACE=my-ns KC_REALM=my-realm ./keycloak/install.sh
```

Components deployed:
- **PostgreSQL** — Keycloak backend database (5Gi PVC)
- **Keycloak 26.1** — identity/access management server

The install script creates the `marketing` realm (configurable via `KC_REALM`). Realm clients, users, and roles are configured by the top-level `deploy.sh`.

## Uninstall (reverse order)

```bash
./keycloak/uninstall.sh          # PVCs preserved; see script output to delete them
./mlflow/uninstall.sh            # PVCs preserved; see script output to delete them
./guardrails/uninstall.sh
./models/uninstall.sh            # PVCs preserved; see script output to delete them
```
