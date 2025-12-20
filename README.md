# Python Mutating Admission Webhook (env injector)

This example runs a small Python webhook that injects a specified environment variable into a specific Pod (by namespace and name) on CREATE.

What it does:
- Watches CREATE operations for Pods.
- If the Pod matches `TARGET_NAMESPACE` and has label `TARGET_LABEL_KEY=TARGET_LABEL_VALUE`, injects/updates `INJECT_ENV_NAME=INJECT_ENV_VALUE` in all containers.

Contents:
- `webhook.py`: Flask server implementing AdmissionReview v1 mutation.
- `Dockerfile`, `requirements.txt`: build/run the webhook image.
- `manifests.yaml`: Namespace, ServiceAccount, Deployment, Service, MutatingWebhookConfiguration (with a placeholder `caBundle`).
- `gen-certs.sh`: Generates a self-signed CA and server cert and creates the TLS secret.
- `patch-ca-bundle.sh`: Patches the webhook `caBundle` with the CA.

## Build and deploy

1) Build and push your image:
```bash
cd /home/michey/llmd_aug2025/vllmbench/profiler
docker build -t <registry>/env-injector:latest .
docker push <registry>/env-injector:latest
```

2) Edit `manifests.yaml`:
- Set the Deployment image to `<registry>/env-injector:latest`
- Optionally change the default env:
  - `TARGET_NAMESPACE`, `TARGET_LABEL_KEY`, `TARGET_LABEL_VALUE`
  - `INJECT_ENV_NAME`, `INJECT_ENV_VALUE`

3) Apply manifests:
```bash
kubectl apply -f manifests.yaml
```

4) Generate certs and create secret:
```bash
NS=vllm-profiler SVC=env-injector ./gen-certs.sh
```

5) Patch the webhook `caBundle`:
```bash
NS=vllm-profiler SVC=env-injector ./patch-ca-bundle.sh
```

6) Verify the webhook:
```bash
kubectl -n vllm-profiler get deploy env-injector
kubectl get mutatingwebhookconfiguration env-injector-webhook -o yaml | grep -n caBundle
```

## Test

Create a pod matching the configured namespace and label, for example:
```bash
kubectl -n default run example-pod \
  --image=registry.k8s.io/pause:3.9 \
  --labels=inject=true \
  --restart=Never --dry-run=client -o yaml | kubectl apply -f -
kubectl -n default get pod example-pod -o jsonpath='{.spec.containers[0].env}'; echo
```
You should see the injected `INJECT_ENV_NAME` with value.

## Notes
- The webhook uses TLS from secret `env-injector-certs` mounted at `/tls`.
- If the pod already has the env var, the webhook replaces its value.
- The webhook only mutates when both `TARGET_NAMESPACE` and `TARGET_LABEL_KEY/TARGET_LABEL_VALUE` match; otherwise it allows without changes.
- `validate_webhook.sh` can run a minimal validation pod when `DO_SIMPLE_TEST=1`.
- `doit.sh` gates the post-deploy VLLM log/copy loop behind `DO_VLLM_TEST=1` (skipped by default).


