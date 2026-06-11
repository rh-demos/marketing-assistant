import os
import sys


def setup_telemetry():
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "").strip()
    if not endpoint:
        return
    try:
        import mlflow

        name = os.environ.get("MLFLOW_EXPERIMENT_NAME", "marketing-assistant")
        exp = mlflow.set_experiment(name)
        exp_id = exp.experiment_id

        existing = os.environ.get("OTEL_EXPORTER_OTLP_TRACES_HEADERS", "")
        attr = f"x-mlflow-experiment-id={exp_id}"
        os.environ["OTEL_EXPORTER_OTLP_TRACES_HEADERS"] = f"{existing},{attr}" if existing else attr

        print(f"[tracing] MLflow tracing → OTLP {endpoint} (experiment={name}, id={exp_id})", file=sys.stderr)
    except Exception as e:
        print(f"[tracing] init failed: {e}", file=sys.stderr)
