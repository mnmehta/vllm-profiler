#!/usr/bin/env python3
import base64
import json
import os
import logging
from typing import Any, Dict, List

from flask import Flask, jsonify, request

app = Flask(__name__)

# Configuration via environment variables
TARGET_NAMESPACE = os.getenv("TARGET_NAMESPACE", "")
TARGET_LABEL_KEY = os.getenv("TARGET_LABEL_KEY", "")
TARGET_LABEL_VALUE = os.getenv("TARGET_LABEL_VALUE", "")
INJECT_ENV_NAME = os.getenv("INJECT_ENV_NAME", "")
INJECT_ENV_VALUE = os.getenv("INJECT_ENV_VALUE", "")
PORT = int(os.getenv("WEBHOOK_PORT", "8443"))
TLS_CERT_FILE = os.getenv("TLS_CERT_FILE", "/tls/tls.crt")
TLS_KEY_FILE = os.getenv("TLS_KEY_FILE", "/tls/tls.key")
LOG_LEVEL = os.getenv("LOG_LEVEL", "DEBUG").upper()
logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.DEBUG), format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("env-injector")

FILES_VOLUME_NAME = "env-injector-files"
FILES_CONFIGMAP_NAME = "env-injector-files"
FILE_KEYS = [
    {"key": "my_method.py", "mountPath": "/home/vllm/my_method.py"},
    {"key": "hotreload.py", "mountPath": "/home/vllm/hotreload/hotreload.py"},
    {"key": "sitecustomize.py", "mountPath": "/home/vllm/hotreload/sitecustomize.py"},
]

def build_env_patch_for_pod(pod: Dict[str, Any], env_name: str, env_value: str) -> List[Dict[str, Any]]:
    patch: List[Dict[str, Any]] = []
    containers = pod.get("spec", {}).get("containers", [])

    logger.debug("Building env patch for %d container(s); target env '%s'='%s'", len(containers), env_name, env_value)

    for container_index, container in enumerate(containers):
        env_list = container.get("env", [])
        cname = container.get("name", f"idx-{container_index}")
        logger.debug("Inspecting container '%s' (index=%d); current env count=%d", cname, container_index, len(env_list))
        # Find existing env var index if present
        existing_index = -1
        for i, item in enumerate(env_list):
            if item.get("name") == env_name:
                existing_index = i
                break

        if existing_index >= 0:
            logger.debug("Container '%s': replacing existing env '%s' at index %d", cname, env_name, existing_index)
            patch.append({
                "op": "replace",
                "path": f"/spec/containers/{container_index}/env/{existing_index}/value",
                "value": env_value,
            })
        else:
            if env_list:
                logger.debug("Container '%s': appending new env '%s'", cname, env_name)
                patch.append({
                    "op": "add",
                    "path": f"/spec/containers/{container_index}/env/-",
                    "value": {"name": env_name, "value": env_value},
                })
            else:
                logger.debug("Container '%s': creating env list with '%s'", cname, env_name)
                patch.append({
                    "op": "add",
                    "path": f"/spec/containers/{container_index}/env",
                    "value": [{"name": env_name, "value": env_value}],
                })

    logger.debug("Patch operations prepared: %s", json.dumps(patch))
    return patch

def build_files_volume_patch_for_pod(pod: Dict[str, Any]) -> List[Dict[str, Any]]:
    patch: List[Dict[str, Any]] = []
    spec = pod.get("spec", {}) or {}
    volumes = spec.get("volumes", [])
    containers = spec.get("containers", [])

    # Add the files volume if missing
    volume_present = any(v.get("name") == FILES_VOLUME_NAME for v in volumes)
    if not volume_present:
        logger.debug("Adding volume '%s' from ConfigMap '%s'", FILES_VOLUME_NAME, FILES_CONFIGMAP_NAME)
        if volumes:
            patch.append({
                "op": "add",
                "path": "/spec/volumes/-",
                "value": {
                    "name": FILES_VOLUME_NAME,
                    "configMap": {
                        "name": FILES_CONFIGMAP_NAME
                    }
                }
            })
        else:
            patch.append({
                "op": "add",
                "path": "/spec/volumes",
                "value": [{
                    "name": FILES_VOLUME_NAME,
                    "configMap": {
                        "name": FILES_CONFIGMAP_NAME
                    }
                }]
            })
    else:
        logger.debug("Volume '%s' already present; skipping add", FILES_VOLUME_NAME)

    # For each container, add volumeMounts for each file using subPath
    for idx, c in enumerate(containers):
        mounts = c.get("volumeMounts", [])
        existing_mount_paths = {m.get("mountPath") for m in mounts}
        add_list = []
        for f in FILE_KEYS:
            if f["mountPath"] in existing_mount_paths:
                logger.debug("Container %s already has mountPath %s", c.get("name", idx), f["mountPath"])
                continue
            add_list.append({
                "name": FILES_VOLUME_NAME,
                "mountPath": f["mountPath"],
                "subPath": f["key"],
                "readOnly": True,
            })
        if add_list:
            if mounts:
                for m in add_list:
                    logger.debug("Adding volumeMount to container %s: %s", c.get("name", idx), m)
                    patch.append({
                        "op": "add",
                        "path": f"/spec/containers/{idx}/volumeMounts/-",
                        "value": m
                    })
            else:
                logger.debug("Creating volumeMounts for container %s with %d mount(s)", c.get("name", idx), len(add_list))
                patch.append({
                    "op": "add",
                    "path": f"/spec/containers/{idx}/volumeMounts",
                    "value": add_list
                })

    logger.debug("Files volume/mount patch prepared: %s", json.dumps(patch))
    return patch


@app.route("/healthz", methods=["GET"])
def healthz():
    return "ok", 200


@app.route("/mutate", methods=["POST"])
def mutate():
    review = request.get_json(force=True, silent=True) or {}
    req = review.get("request", {})
    uid = req.get("uid")

    logger.debug("AdmissionReview received: uid=%s kind=%s.%s op=%s",
                 uid,
                 req.get("kind", {}).get("group", ""),
                 req.get("kind", {}).get("kind", ""),
                 req.get("operation", ""))

    # Default AdmissionReview response: allow without changes
    response_body: Dict[str, Any] = {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": {
            "uid": uid,
            "allowed": True,
        },
    }

    if req.get("kind", {}).get("kind") != "Pod":
        logger.debug("Skipping non-Pod kind")
        return jsonify(response_body)

    namespace = req.get("namespace", "")
    obj = req.get("object", {}) or {}
    labels = obj.get("metadata", {}).get("labels", {}) or {}
    name = obj.get("metadata", {}).get("name", "")

    logger.debug("Pod admission: ns=%s name=%s labels=%s", namespace, name, labels)
    logger.debug("Filter config: TARGET_NAMESPACE=%s TARGET_LABEL_KEY=%s TARGET_LABEL_VALUE=%s INJECT_ENV_NAME=%s",
                 TARGET_NAMESPACE, TARGET_LABEL_KEY, TARGET_LABEL_VALUE, INJECT_ENV_NAME)

    # Only mutate pods with matching namespace and label key/value
    if not (TARGET_NAMESPACE and TARGET_LABEL_KEY and TARGET_LABEL_VALUE and INJECT_ENV_NAME):
        logger.debug("Missing required filter or injection config; allowing without patch")
        return jsonify(response_body)
    if namespace != TARGET_NAMESPACE:
        logger.debug("Namespace mismatch: got '%s' expected '%s'; allowing without patch", namespace, TARGET_NAMESPACE)
        return jsonify(response_body)
    if labels.get(TARGET_LABEL_KEY) != TARGET_LABEL_VALUE:
        logger.debug("Label mismatch: pod label '%s'='%s' expected value '%s'; allowing without patch",
                     TARGET_LABEL_KEY, labels.get(TARGET_LABEL_KEY), TARGET_LABEL_VALUE)
        return jsonify(response_body)

    patch_ops = build_env_patch_for_pod(obj, INJECT_ENV_NAME, INJECT_ENV_VALUE)
    patch_ops.extend(build_files_volume_patch_for_pod(obj))

    if patch_ops:
        logger.debug("Emitting JSONPatch with %d operation(s)", len(patch_ops))
        patch_str = json.dumps(patch_ops)
        response_body["response"]["patchType"] = "JSONPatch"
        response_body["response"]["patch"] = base64.b64encode(patch_str.encode("utf-8")).decode("utf-8")
    else:
        logger.debug("No patch operations generated; allowing without patch")

    return jsonify(response_body)


if __name__ == "__main__":
    # Basic validation on startup
    if not os.path.exists(TLS_CERT_FILE) or not os.path.exists(TLS_KEY_FILE):
        raise SystemExit(f"TLS cert/key not found at {TLS_CERT_FILE} / {TLS_KEY_FILE}")

    logger.info("Starting env-injector webhook on port %d", PORT)
    logger.info("Effective config: TARGET_NAMESPACE=%s TARGET_LABEL_KEY=%s TARGET_LABEL_VALUE=%s INJECT_ENV_NAME=%s LOG_LEVEL=%s",
                TARGET_NAMESPACE, TARGET_LABEL_KEY, TARGET_LABEL_VALUE, INJECT_ENV_NAME, LOG_LEVEL)
    logger.info("TLS cert=%s key=%s", TLS_CERT_FILE, TLS_KEY_FILE)

    app.run(
        host="0.0.0.0",
        port=PORT,
        ssl_context=(TLS_CERT_FILE, TLS_KEY_FILE),
        debug=False,
    )


