# vLLM Profiler Configuration Examples

This document shows various ways to configure the vLLM profiler.

## Configuration Priority

Configuration is loaded in this order (later sources override earlier ones):

1. **Hardcoded defaults** in sitecustomize.py
2. **profiler_config.yaml** file (mounted from ConfigMap)
3. **Environment variables** (highest priority)
4. **Pod annotations** (converted to environment variables by webhook)

## Method 1: Using profiler_config.yaml (Recommended for defaults)

Edit `profiler_config.yaml` and redeploy the ConfigMap:

```yaml
# profiler_config.yaml
profiling_ranges: "50-100,200-300"  # Multiple ranges!
activities: "CPU,CUDA"
options:
  record_shapes: true
  with_stack: true
  profile_memory: false
```

Then update the ConfigMap:

```bash
oc delete configmap env-injector-files -n downstream-llm-d
oc apply -k .
```

**Advantages:**
- Single file to manage
- No pod restarts needed (only new pods get new config)
- Easy to version control

## Method 2: Using Pod Annotations (Recommended for per-pod customization)

Add annotations to your pod spec to override profiler settings for that specific pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-vllm-pod
  namespace: downstream-llm-d
  labels:
    llm-d.ai/inferenceServing: "true"
  annotations:
    # Profile two ranges: calls 50-100 and 200-300
    vllm.profiler/ranges: "50-100,200-300"

    # Only profile CUDA activity (skip CPU)
    vllm.profiler/activities: "CUDA"

    # Enable memory profiling
    vllm.profiler/memory: "true"

    # Custom output filename
    vllm.profiler/output: "my_custom_trace.json"

    # Enable debug logging
    vllm.profiler/debug: "true"
spec:
  containers:
  - name: vllm
    image: vllm/vllm-openai:latest
    # ... rest of pod spec
```

**Advantages:**
- Per-pod customization
- No ConfigMap changes needed
- Immediate effect on new pods

## Method 3: Using Environment Variables

If you're creating pods manually or via other tools, you can inject environment variables directly:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-vllm-pod
  namespace: downstream-llm-d
  labels:
    llm-d.ai/inferenceServing: "true"
spec:
  containers:
  - name: vllm
    image: vllm/vllm-openai:latest
    env:
    - name: VLLM_PROFILER_RANGES
      value: "0-50,100-150"
    - name: VLLM_PROFILER_ACTIVITIES
      value: "CPU,CUDA"
    - name: VLLM_PROFILER_MEMORY
      value: "true"
    - name: VLLM_PROFILER_OUTPUT
      value: "trace_pid{pid}_rank{rank}.json"
    # ... rest of container spec
```

**Advantages:**
- Full control over each pod
- Works with any deployment tool (Helm, Kustomize, etc.)

## Supported Configuration Options

### Profiling Ranges

Specify which model execution calls to profile:

| Method | Example | Effect |
|--------|---------|--------|
| ConfigMap | `profiling_ranges: "100-150"` | Profile calls 100-150 |
| Annotation | `vllm.profiler/ranges: "50-100,200-300"` | Profile 50-100 AND 200-300 |
| Env Var | `VLLM_PROFILER_RANGES="0-50"` | Profile first 50 calls |

**Format:** `"start-end"` or `"start1-end1,start2-end2,..."` for multiple ranges.

### Activities

Control what to profile:

| Value | Description |
|-------|-------------|
| `"CPU"` | CPU activity only |
| `"CUDA"` | CUDA/GPU activity only |
| `"CPU,CUDA"` | Both (default) |

### Boolean Options

Set to `"true"` or `"false"`:

| Option | Default | Description |
|--------|---------|-------------|
| `record-shapes` / `VLLM_PROFILER_RECORD_SHAPES` | `true` | Record tensor shapes |
| `with-stack` / `VLLM_PROFILER_WITH_STACK` | `true` | Capture Python stack traces |
| `memory` / `VLLM_PROFILER_MEMORY` | `false` | Profile memory allocations |
| `debug` / `VLLM_PROFILER_DEBUG` | `false` | Enable debug logging |

### Output File Pattern

Customize the output trace filename:

| Placeholder | Replaced With |
|-------------|---------------|
| `{pid}` | Process ID |
| `{rank}` | Tensor parallel rank (if available) |

**Examples:**
- `"trace_pid{pid}.json"` → `trace_pid12345.json`
- `"trace_rank{rank}_pid{pid}.json"` → `trace_rank0_pid12345.json`
- `"my_profile.json"` → `my_profile.json` (static name)

## Common Use Cases

### Use Case 1: Profile startup performance

Profile the first 50 model executions to see initialization overhead:

**Annotation:**
```yaml
annotations:
  vllm.profiler/ranges: "0-50"
```

### Use Case 2: Profile multiple windows

Compare performance at different stages (warmup, steady-state, after N requests):

**Annotation:**
```yaml
annotations:
  vllm.profiler/ranges: "0-50,100-150,500-550"
```

### Use Case 3: Memory profiling

Enable memory profiling to find memory leaks or allocations:

**Annotation:**
```yaml
annotations:
  vllm.profiler/memory: "true"
  vllm.profiler/ranges: "100-200"  # Longer range for memory analysis
```

### Use Case 4: CUDA-only profiling

Skip CPU profiling to reduce overhead and focus on GPU performance:

**Annotation:**
```yaml
annotations:
  vllm.profiler/activities: "CUDA"
  vllm.profiler/with-stack: "false"  # Further reduce overhead
```

### Use Case 5: Per-rank trace files

When using tensor parallelism, create separate trace files for each rank:

**ConfigMap:**
```yaml
output:
  file_pattern: "trace_rank{rank}_pid{pid}.json"
```

## Testing Configuration

To test your configuration without creating a full vLLM deployment:

**1. Check startup messages:**

```bash
kubectl logs <pod-name> | grep profiler
```

Look for:
```
[profiler] vLLM profiler installed - will profile ranges: [(50, 100), (200, 300)]
```

**2. Enable debug mode to see configuration details:**

```yaml
annotations:
  vllm.profiler/debug: "true"
```

Then check logs for:
```
[profiler-config] Loaded configuration:
  Ranges: [(50, 100), (200, 300)]
  Activities: ['CPU', 'CUDA']
  Output: trace_pid{pid}.json
```

**3. Verify profiler activation:**

Watch logs for profiler start/stop messages:

```bash
kubectl logs -f <pod-name> | grep -E "\[profiler\]"
```

Expected output:
```
[profiler] Starting profiler for range 50-100 (call #50)
[profiler] Stopping profiler for range 50-100 (call #100)
[profiler] Exported trace to: trace_pid12345.json
[profiler] Starting profiler for range 200-300 (call #200)
...
```

## Changing Configuration Without Rebuilding

### For all new pods (via ConfigMap):

```bash
# 1. Edit profiler_config.yaml
vim profiler_config.yaml

# 2. Update ConfigMap
oc delete configmap env-injector-files -n downstream-llm-d
oc apply -k .

# 3. New pods will use new configuration automatically
```

### For specific pods (via annotations):

Just create pods with different annotations - no rebuild needed!

```bash
# Create pod with custom profiling ranges
kubectl run my-vllm-pod \
  --namespace=downstream-llm-d \
  --labels="llm-d.ai/inferenceServing=true" \
  --annotations="vllm.profiler/ranges=0-100" \
  --image=vllm/vllm-openai:latest \
  -- vllm serve <model-name>
```

## Troubleshooting

### Configuration not being applied

**Check webhook logs:**
```bash
kubectl logs -n vllm-profiler deployment/env-injector | grep profiler
```

**Verify annotations were detected:**
```
Found profiler annotation 'vllm.profiler/ranges' -> VLLM_PROFILER_RANGES='50-100,200-300'
```

### YAML config not loading

**Check if PyYAML is installed in vLLM container:**
```bash
kubectl exec <pod-name> -- python -c "import yaml; print('OK')"
```

If PyYAML is missing, configuration will fall back to environment variables.

### Wrong profiling ranges

**Check environment variables in pod:**
```bash
kubectl exec <pod-name> -- env | grep VLLM_PROFILER
```

## Best Practices

1. **Use ConfigMap for defaults** - Set sensible defaults in profiler_config.yaml
2. **Use annotations for customization** - Override per pod as needed
3. **Start with conservative ranges** - Use narrow ranges initially, expand as needed
4. **Disable stack traces in production** - Set `with-stack: false` to reduce overhead
5. **Use multiple small ranges** - `"50-60,100-110"` instead of one large `"50-110"`
6. **Enable debug mode during testing** - Helps verify configuration is applied correctly
