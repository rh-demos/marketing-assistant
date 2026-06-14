"""
Knative Service helper functions for Delivery Manager
"""
from kubernetes import client
from kubernetes.client.rest import ApiException
from typing import Dict, Any
import logging

logger = logging.getLogger(__name__)


def create_knative_service(
    service_name: str,
    namespace: str,
    image: str,
    container_port: int,
    env_vars: Dict[str, str],
    min_scale: int = 0,
    max_scale: int = 3,
    timeout_seconds: int = 120,
    container_concurrency: int = 50,
    visibility: str = "",  # "" = public, "cluster-local" = internal only
    scale_to_zero_retention: str = "30m",
    autoscale_window: str = "60s",
) -> Dict[str, Any]:
    """
    Create Knative Service using CustomObjectsApi

    Returns:
        dict with status ("success" or "error") and service object or error message
    """

    # Build Knative Service spec
    service_spec = {
        "apiVersion": "serving.knative.dev/v1",
        "kind": "Service",
        "metadata": {
            "name": service_name,
            "namespace": namespace,
            "labels": {
                "app": "campaign-landing",
                "managed-by": "delivery-manager"
            }
        },
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        # Autoscaling annotations must be under spec.template.metadata.annotations
                        "autoscaling.knative.dev/class": "kpa.autoscaling.knative.dev",
                        "autoscaling.knative.dev/metric": "concurrency",
                        "autoscaling.knative.dev/min-scale": str(min_scale),
                        "autoscaling.knative.dev/max-scale": str(max_scale),
                        "autoscaling.knative.dev/target": "50",
                        "autoscaling.knative.dev/scale-to-zero-pod-retention-period": scale_to_zero_retention,
                        "autoscaling.knative.dev/window": autoscale_window,
                    }
                },
                "spec": {
                    "timeoutSeconds": timeout_seconds,
                    "containerConcurrency": container_concurrency,
                    "containers": [{
                        "name": "landing",
                        "image": image,
                        "imagePullPolicy": "Always",
                        "ports": [{
                            "containerPort": container_port,
                            "protocol": "TCP",
                            "name": "http1"  # Knative requirement
                        }],
                        # Remove PORT env var - reserved by Knative
                        "env": [{"name": k, "value": v} for k, v in env_vars.items() if k != "PORT"],
                        "resources": {
                            "requests": {"memory": "128Mi", "cpu": "50m"},
                            "limits": {"memory": "256Mi", "cpu": "200m"}
                        },
                        "livenessProbe": {
                            "httpGet": {"path": "/", "port": container_port},
                            "initialDelaySeconds": 0,
                            "periodSeconds": 10
                        },
                        "readinessProbe": {
                            "httpGet": {"path": "/", "port": container_port},
                            "initialDelaySeconds": 0,
                            "periodSeconds": 5
                        }
                    }]
                    # Pod-level securityContext removed - not allowed by Knative
                }
            }
        }
    }

    # Add visibility annotation for cluster-local access if needed
    if visibility == "cluster-local":
        service_spec["metadata"]["annotations"] = service_spec["metadata"].get("annotations", {})
        service_spec["metadata"]["annotations"]["serving.knative.dev/visibility"] = "cluster-local"

    # Create using CustomObjectsApi
    custom_api = client.CustomObjectsApi()

    try:
        result = custom_api.create_namespaced_custom_object(
            group="serving.knative.dev",
            version="v1",
            namespace=namespace,
            plural="services",
            body=service_spec,
            pretty=True
        )
        logger.info(f"Knative Service '{service_name}' created in namespace '{namespace}'")
        return {"status": "success", "service": result}

    except ApiException as e:
        if e.status == 409:
            # Service already exists, patch it
            try:
                result = custom_api.patch_namespaced_custom_object(
                    group="serving.knative.dev",
                    version="v1",
                    namespace=namespace,
                    plural="services",
                    name=service_name,
                    body=service_spec
                )
                logger.info(f"Knative Service '{service_name}' updated in namespace '{namespace}'")
                return {"status": "success", "service": result}
            except ApiException as patch_error:
                logger.error(f"Failed to patch Knative Service: {patch_error}")
                return {"status": "error", "message": str(patch_error)}

        logger.error(f"Failed to create Knative Service: {e}")
        return {"status": "error", "message": str(e)}


def delete_knative_service(service_name: str, namespace: str) -> Dict[str, Any]:
    """
    Delete Knative Service

    Returns:
        dict with status ("success" or "error")
    """
    custom_api = client.CustomObjectsApi()

    try:
        custom_api.delete_namespaced_custom_object(
            group="serving.knative.dev",
            version="v1",
            namespace=namespace,
            plural="services",
            name=service_name
        )
        logger.info(f"Knative Service '{service_name}' deleted from namespace '{namespace}'")
        return {"status": "success"}

    except ApiException as e:
        if e.status == 404:
            logger.warning(f"Knative Service '{service_name}' not found (already deleted?)")
            return {"status": "success"}  # Already deleted

        logger.error(f"Failed to delete Knative Service: {e}")
        return {"status": "error", "message": str(e)}


def get_knative_service_url(service_name: str, namespace: str) -> str:
    """
    Get Knative Service URL from status

    Returns:
        str: Service URL or empty string if not ready
    """
    custom_api = client.CustomObjectsApi()

    try:
        service = custom_api.get_namespaced_custom_object(
            group="serving.knative.dev",
            version="v1",
            namespace=namespace,
            plural="services",
            name=service_name
        )

        # Knative Service status.url contains the public URL
        url = service.get("status", {}).get("url", "")
        if url:
            logger.info(f"Knative Service URL: {url}")
            return url
        else:
            logger.warning(f"Knative Service '{service_name}' not ready yet (no URL in status)")
            return ""

    except ApiException as e:
        logger.error(f"Failed to get Knative Service status: {e}")
        return ""
