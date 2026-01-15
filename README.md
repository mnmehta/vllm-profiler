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
│ User creates Pod with ANY matching label:       │
│  - llm-d.ai/inferenceServing=true  OR           │
│  - app=vllm  OR                                 │
│  - vllm.profiler/enabled=true                   │
│ Optional annotations for configuration:         │
│  - vllm.profiler/ranges="50-100,200-300"        │
│  - vllm.profiler/export-trace="false"           │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ Mutating Webhook (webhook.py)                   │
│  - Checks namespace & label (OR logic)          │
│  - Injects: PYTHONPATH=/home/vllm/profiler      │
│  - Converts annotations to env vars             │
│  - Mounts: sitecustomize.py + config from CM    │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│ Pod starts → Python auto-loads sitecustomize.py │
│  Loads config from YAML & env vars              │
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
│ Profiler runs on configured ranges (e.g. 100-150│
│  Optionally exports: trace_pid{pid}.json        │
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

Edit `manifests.yaml` to configure target namespace and label selectors:

```yaml
env:
  - name: TARGET_NAMESPACE
    value: "downstream-llm-d"
  # Multi-label selector (OR logic): pod with ANY of these labels will be instrumented
  - name: TARGET_LABELS
    value: "llm-d.ai/inferenceServing=true,app=vllm,vllm.profiler/enabled=true"
```

The webhook uses **OR logic** - a pod matching ANY of the specified labels will be profiled. No webhook rebuild needed to change labels.

### Updating Label Selectors Without Rebuilding

You can change the target labels without rebuilding the webhook container:

```bash
# Update TARGET_LABELS environment variable
oc set env deployment/env-injector -n vllm-profiler \
  TARGET_LABELS="llm-d.ai/inferenceServing=true,app=vllm,vllm.profiler/enabled=true,role=worker"

# Webhook pod will automatically restart with new configuration
# Verify new configuration:
oc logs -n vllm-profiler deployment/env-injector | grep "Target labels"
```

This allows you to dynamically add or remove pod types to profile without any downtime.

### Create Profiled Pod

Create a vLLM pod in the target namespace with a matching label:

```bash
# Basic: Pod will automatically be injected with default profiler configuration
kubectl run my-vllm-pod \
  -n downstream-llm-d \
  --labels="llm-d.ai/inferenceServing=true" \
  --image=vllm/vllm-openai:latest \
  -- vllm serve <model-name>
```

Or use pod annotations for custom profiler configuration:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-vllm-pod
  namespace: downstream-llm-d
  labels:
    app: vllm  # Matches one of the target labels
  annotations:
    # Custom profiling ranges (multiple windows)
    vllm.profiler/ranges: "50-100,200-300"
    # Disable trace file export (reduce I/O)
    vllm.profiler/export-trace: "false"
    # Enable debug logging
    vllm.profiler/debug: "true"
spec:
  containers:
  - name: vllm
    image: vllm/vllm-openai:latest
    command: ["vllm", "serve", "<model-name>"]
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
├── sitecustomize.py            # Profiler import hook (injected into pods)
├── profiler_config.yaml        # Default profiler configuration
├── webhook.py                  # Flask mutating admission webhook
├── manifests.yaml              # Kubernetes resources
├── kustomization.yaml          # ConfigMap generator
├── Dockerfile                  # Webhook container image
├── requirements.txt            # Python dependencies
├── deploy.sh                   # Deployment automation script
├── teardown.sh                 # Cleanup script
├── gen-certs.sh                # TLS certificate generation
├── patch-ca-bundle.sh          # Webhook CA bundle patching
├── validate_webhook.sh         # Validation tool
├── test-profiler.sh            # Standalone profiler testing
├── test-profiler-features.yaml # Feature testing examples
├── CONFIGURATION_EXAMPLES.md   # Configuration guide
└── README.md                   # This file
```

## How It Works

### 1. Admission Webhook (webhook.py)

Flask-based mutating webhook that:
- Listens for Pod CREATE operations
- Filters by namespace and **multiple label selectors (OR logic)**
- Extracts profiler configuration from pod annotations
- Converts annotations to environment variables
- Injects `PYTHONPATH=/home/vllm/profiler` environment variable
- Mounts `sitecustomize.py` and `profiler_config.yaml` from ConfigMap

### 2. Profiler Import Hook (sitecustomize.py)

Python module that:
- Auto-loads when Python starts (via PYTHONPATH)
- Loads configuration from **3 sources** (priority order):
  1. Environment variables (highest priority)
  2. `profiler_config.yaml` file
  3. Hardcoded defaults (lowest priority)
- Installs a `sys.meta_path` finder to intercept `vllm.v1.worker.gpu_worker` import
- Wraps `Worker.execute_model` with torch.profiler
- Records CPU+CUDA activity for configured call ranges
- Optionally exports Chrome trace JSON file

### 3. Profiler Configuration

Configuration is managed via `ProfilerConfig` class with multi-source support:

**Default settings** (from profiler_config.yaml):
```yaml
profiling_ranges: "100-150"  # Can specify multiple: "50-100,200-300"
activities: "CPU,CUDA"
options:
  record_shapes: true
  with_stack: true
  profile_memory: false
output:
  export_chrome_trace: true  # Set false to disable trace export
  file_pattern: "trace_pid{pid}.json"
```

**Per-pod override** (via annotations):
```yaml
annotations:
  vllm.profiler/ranges: "50-100,200-300"      # Multiple profiling windows
  vllm.profiler/export-trace: "false"         # Disable trace export
  vllm.profiler/debug: "true"                 # Enable debug logging
  vllm.profiler/activities: "CPU,CUDA"
  vllm.profiler/record-shapes: "true"
  vllm.profiler/with-stack: "true"
  vllm.profiler/memory: "false"
  vllm.profiler/output: "custom_trace.json"
```

See [CONFIGURATION_EXAMPLES.md](CONFIGURATION_EXAMPLES.md) for comprehensive configuration guide.

## Advanced Usage

### Environment Variables

**Webhook Configuration:**
- `TARGET_NAMESPACE`: Namespace to target (default: "downstream-llm-d")
- `TARGET_LABELS`: Comma-separated label selectors with OR logic (e.g., "key1=val1,key2=val2")
- `TARGET_LABEL_KEY`: Legacy single label key (deprecated, use TARGET_LABELS)
- `TARGET_LABEL_VALUE`: Legacy single label value (deprecated, use TARGET_LABELS)
- `INJECT_ENV_NAME`: Environment variable to inject (default: "PYTHONPATH")
- `INJECT_ENV_VALUE`: Environment variable value (default: "/home/vllm/profiler")
- `LOG_LEVEL`: Webhook logging level (default: "DEBUG")

**Deployment:**
- `CONTAINER_RUNTIME`: Container runtime to use (default: "podman")
- `IMAGE_REGISTRY`: Image registry (default: "quay.io/mimehta")
- `IMAGE_TAG`: Image tag (default: "latest")

**Profiler Configuration (injected via pod annotations or set manually):**
- `VLLM_PROFILER_RANGES`: Profiling call ranges (e.g., "100-150" or "50-100,200-300")
- `VLLM_PROFILER_ACTIVITIES`: Activities to profile (e.g., "CPU,CUDA")
- `VLLM_PROFILER_RECORD_SHAPES`: Record tensor shapes (true/false)
- `VLLM_PROFILER_WITH_STACK`: Capture stack traces (true/false)
- `VLLM_PROFILER_MEMORY`: Profile memory allocations (true/false)
- `VLLM_PROFILER_OUTPUT`: Custom trace output file pattern
- `VLLM_PROFILER_EXPORT_TRACE`: Enable/disable trace export (true/false)
- `VLLM_PROFILER_DEBUG`: Enable debug logging (true/false)

### Testing Without Kubernetes

Test the profiler standalone with a local vLLM instance:

```bash
# Requires access to a pod running vLLM
./test-profiler.sh
```

### Customizing Profiler Settings

**Method 1: Update ConfigMap (affects all new pods):**

Edit `profiler_config.yaml` and update the ConfigMap:

```yaml
profiling_ranges: "200-300"  # Change profiling window
activities: "CPU,CUDA"
options:
  profile_memory: true       # Enable memory profiling
  record_shapes: true
```

Then update ConfigMap (no webhook rebuild needed):

```bash
# Delete and recreate ConfigMap with updated configuration
oc delete configmap env-injector-files -n downstream-llm-d
oc apply -k .

# New pods will automatically get the updated configuration
# Existing pods need to be restarted to pick up changes
```

**Note:** Updating the ConfigMap does not require rebuilding or restarting the webhook. Only the target namespace's ConfigMap is updated.

**Method 2: Per-pod configuration (via annotations):**

Add annotations to your pod spec (no ConfigMap update needed):

```yaml
metadata:
  annotations:
    vllm.profiler/ranges: "200-300"
    vllm.profiler/memory: "true"
    vllm.profiler/export-trace: "false"
```

**Method 3: Test different configurations:**

See `test-profiler-features.yaml` for examples of different configurations.

## Key Features

### 1. Multiple Label Selectors with OR Logic

The webhook supports multiple label selectors - a pod matching **ANY** of the configured labels will be profiled:

```yaml
TARGET_LABELS: "llm-d.ai/inferenceServing=true,app=vllm,vllm.profiler/enabled=true"
```

This eliminates the need to rebuild the webhook when adding new pod types to profile.

### 2. Multiple Profiling Ranges

Profile multiple non-contiguous call ranges in a single session:

```yaml
vllm.profiler/ranges: "50-100,200-300,500-600"
```

This is useful for:
- Capturing warmup vs steady-state performance
- Comparing different phases of model execution
- Reducing profiling overhead while still capturing key intervals

### 3. Optional Trace Export

Disable trace file export to reduce I/O overhead in production:

```yaml
vllm.profiler/export-trace: "false"  # Still prints profiler table to logs
```

### 4. Dynamic Configuration

No webhook rebuilds needed - configure profiling via:
- **ConfigMap** (cluster-wide defaults)
- **Pod annotations** (per-pod overrides)
- **Environment variables** (highest priority)

### 5. Zero Code Changes

Profiling is completely transparent to the application:
- No vLLM source code modifications
- No container rebuilds
- No application downtime
- Automatic instrumentation via import hooks

## What Requires Rebuild vs Runtime Update

### No Rebuild Required ✅

These changes can be made without rebuilding the webhook container:

1. **Change target labels:**
   ```bash
   oc set env deployment/env-injector -n vllm-profiler TARGET_LABELS="new,labels,here"
   ```

2. **Change target namespace:**
   ```bash
   oc set env deployment/env-injector -n vllm-profiler TARGET_NAMESPACE="new-namespace"
   ```

3. **Update profiler configuration (ConfigMap):**
   ```bash
   oc delete configmap env-injector-files -n downstream-llm-d
   oc apply -k .
   ```

4. **Per-pod configuration:**
   - Just add annotations to your pod spec

### Rebuild Required 🔨

These changes require rebuilding and redeploying the webhook:

1. **Changes to webhook.py logic**
2. **Changes to Python dependencies (requirements.txt)**
3. **Changes to Dockerfile**

To rebuild:
```bash
./deploy.sh  # Rebuilds container image and redeploys
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
- ConfigMap: `env-injector-files` (contains sitecustomize.py and profiler_config.yaml)

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
