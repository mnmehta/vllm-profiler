# vLLM Profiler - Kubernetes Mutating Admission Webhook

A Kubernetes-native profiling system for vLLM GPU workers that uses a mutating admission webhook to transparently inject PyTorch profiler instrumentation into vLLM serving pods.

## Overview

This system enables real-time torch profiling of vLLM model execution without requiring source code modifications or container rebuilds. It works by:

1. **Intercepting pod creation** via Kubernetes mutating admission webhook
2. **Injecting profiler code** via ConfigMap and environment variables
3. **Auto-loading profiler** when Python starts using sitecustomize.py
4. **Instrumenting vLLM** using import hooks to wrap `Worker.execute_model` with torch.profiler
5. **Capturing traces** of CPU+CUDA activity and exporting Chrome trace JSON files

## Architecture

```
┌─────────────────────────────────────────────────┐
│ User creates Pod with label:                    │
│ llm-d.ai/inferenceServing=true                  │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ Mutating Webhook (webhook.py)                   │
│  - Checks namespace & label                     │
│  - Injects: PYTHONPATH=/home/vllm/profiler      │
│  - Mounts: sitecustomize.py from ConfigMap      │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ Pod starts → Python auto-loads sitecustomize.py │
│  Installs import hook in sys.meta_path          │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ vLLM imports vllm.v1.worker.gpu_worker          │
│  Import hook intercepts & wraps execute_model   │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ Profiler runs on calls 100-150                  │
│  Exports: trace<pid>.json (Chrome trace)        │
└─────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- Kubernetes/OpenShift cluster access
- `oc` or `kubectl` CLI
- `podman` or `docker` for building images
- Cluster admin permissions (for MutatingWebhookConfiguration)

### Deploy

```bash
# Deploy webhook and all components
./deploy.sh

# Or skip image build if using existing image
./deploy.sh --skip-build
```

The deployment script will:
1. Build and push the webhook container image
2. Deploy webhook to `vllm-profiler` namespace
3. Create ConfigMap with profiler code in target namespace
4. Generate TLS certificates
5. Configure webhook with CA bundle
6. Validate deployment

### Configuration

Edit `manifests.yaml` to configure target namespace and label selector:

```yaml
env:
  - name: TARGET_NAMESPACE
    value: "downstream-llm-d"          # Namespace to inject profiler into
  - name: TARGET_LABEL_KEY
    value: "llm-d.ai/inferenceServing" # Label key to match
  - name: TARGET_LABEL_VALUE
    value: "true"                       # Label value to match
```

### Create Profiled Pod

Create a vLLM pod in the target namespace with the matching label:

```bash
# Pod will automatically be injected with profiler
kubectl run my-vllm-pod \
  -n downstream-llm-d \
  --labels="llm-d.ai/inferenceServing=true" \
  --image=vllm/vllm-openai:latest \
  -- vllm serve <model-name>
```

### View Profiler Output

The profiler activates automatically after 100 model execution calls:

```bash
# Watch for profiler output (calls 100-150)
kubectl logs -n downstream-llm-d <pod-name> -f | grep -A 50 "begin profiler output"

# Retrieve trace file for visualization
kubectl cp downstream-llm-d/<pod-name>:/path/to/trace<pid>.json ./trace.json

# Open in Chrome
# Navigate to chrome://tracing and load trace.json
```

### Teardown

```bash
# Remove all webhook resources
./teardown.sh

# Or skip confirmation prompt
./teardown.sh --force
```

## Project Structure

```
vllm-profiler/
├── sitecustomize.py        # Profiler import hook (injected into pods)
├── webhook.py              # Flask mutating admission webhook
├── manifests.yaml          # Kubernetes resources
├── kustomization.yaml      # ConfigMap generator
├── Dockerfile              # Webhook container image
├── requirements.txt        # Python dependencies
├── deploy.sh               # Deployment automation script
├── teardown.sh             # Cleanup script
├── gen-certs.sh            # TLS certificate generation
├── patch-ca-bundle.sh      # Webhook CA bundle patching
├── validate_webhook.sh     # Validation tool
├── test-profiler.sh        # Standalone profiler testing
└── README.md               # This file
```

## How It Works

### 1. Admission Webhook (webhook.py)

Flask-based mutating webhook that:
- Listens for Pod CREATE operations
- Filters by namespace and label selector
- Injects `PYTHONPATH=/home/vllm/profiler` environment variable
- Mounts `sitecustomize.py` from ConfigMap to `/home/vllm/profiler/sitecustomize.py`

### 2. Profiler Import Hook (sitecustomize.py)

Python module that:
- Auto-loads when Python starts (via PYTHONPATH)
- Installs a `sys.meta_path` finder to intercept `vllm.v1.worker.gpu_worker` import
- Wraps `Worker.execute_model` with torch.profiler
- Records CPU+CUDA activity for calls 100-150
- Exports Chrome trace JSON file

### 3. Profiler Configuration

Default profiler settings (in sitecustomize.py):

```python
start_profile = 100      # Start profiling at call #100
steps = 50               # Profile for 50 calls (100-150)
activities = [CPU, CUDA] # Profile CPU and CUDA activity
record_shapes = True     # Record tensor shapes
with_stack = True        # Capture stack traces
```

Output file: `${VLLM_TORCH_PROFILE:-trace<pid>.json}`

## Advanced Usage

### Environment Variables

**Webhook Configuration:**
- `TARGET_NAMESPACE`: Namespace to target (default: "downstream-llm-d")
- `TARGET_LABEL_KEY`: Pod label key to match (default: "llm-d.ai/inferenceServing")
- `TARGET_LABEL_VALUE`: Pod label value to match (default: "true")
- `INJECT_ENV_NAME`: Environment variable to inject (default: "PYTHONPATH")
- `INJECT_ENV_VALUE`: Environment variable value (default: "/home/vllm/profiler")
- `LOG_LEVEL`: Webhook logging level (default: "DEBUG")

**Deployment:**
- `CONTAINER_RUNTIME`: Container runtime to use (default: "podman")
- `IMAGE_REGISTRY`: Image registry (default: "quay.io/mimehta")
- `IMAGE_TAG`: Image tag (default: "latest")

**Profiler:**
- `VLLM_TORCH_PROFILE`: Custom trace output file path

### Testing Without Kubernetes

Test the profiler standalone with a local vLLM instance:

```bash
# Requires access to a pod running vLLM
./test-profiler.sh
```

### Customizing Profiler Settings

Edit `sitecustomize.py` and modify the profiler configuration:

```python
def wrap_func_with_profiler(original_func):
    start_profile = 200    # Change start call
    steps = 100             # Change number of calls to profile

    prof = profile(
        activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA],
        record_shapes=True,
        with_stack=True,
        profile_memory=True  # Add memory profiling
    )
    # ...
```

Then redeploy:

```bash
oc delete configmap env-injector-files -n downstream-llm-d
oc apply -k .
```

## Troubleshooting

### Webhook not injecting profiler

Check webhook logs:
```bash
kubectl logs -n vllm-profiler deployment/env-injector
```

Verify webhook configuration:
```bash
kubectl get mutatingwebhookconfiguration env-injector-webhook -o yaml
```

### Profiler not loading in pod

Check pod has correct environment:
```bash
kubectl get pod <pod-name> -n downstream-llm-d -o jsonpath='{.spec.containers[0].env}' | jq
```

Check pod has volume mount:
```bash
kubectl get pod <pod-name> -n downstream-llm-d -o jsonpath='{.spec.containers[0].volumeMounts}' | jq
```

Check pod logs for sitecustomize messages:
```bash
kubectl logs <pod-name> -n downstream-llm-d | grep sitecustomize
```

### Profiler not triggering

The profiler only activates after 100 model execution calls. Send inference requests:
```bash
# Example with vLLM OpenAI-compatible API
curl http://<pod-ip>:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "...", "prompt": "Hello", "max_tokens": 100}'
```

### Validation tool

Run comprehensive validation:
```bash
DO_SIMPLE_TEST=1 PROFILER_NS=vllm-profiler TARGET_NS=downstream-llm-d ./validate_webhook.sh
```

## Resources Created

**Namespace: vllm-profiler**
- Deployment: `env-injector` (webhook)
- Service: `env-injector` (HTTPS on port 443)
- ServiceAccount: `env-injector`
- Secret: `env-injector-certs` (TLS certificates)

**Target Namespace: downstream-llm-d** (configurable)
- ConfigMap: `env-injector-files` (contains sitecustomize.py)

**Cluster-wide:**
- MutatingWebhookConfiguration: `env-injector-webhook`

## Security Considerations

- Webhook requires cluster admin permissions to create MutatingWebhookConfiguration
- Uses self-signed TLS certificates (suitable for development/testing)
- Failure policy is `Ignore` - webhook failures won't block pod creation
- ConfigMap is mounted read-only into pods
- Profiler code runs with same permissions as vLLM process

## License

See LICENSE file.

## Contributing

Contributions welcome! Please open issues or pull requests on the project repository.

## Support

For issues and questions, please open an issue on GitHub.
