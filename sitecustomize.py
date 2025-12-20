import os
import sys
import psutil

# Print PID, process name, and PYTHONPATH at startup
p = psutil.Process(os.getpid())
print(f"========= Using hotreload module pid {os.getpid()} pidname {p.name()} PYTHONPATH {os.environ.get('PYTHONPATH')}")
print(f"[sitecustomize] sys.path:")
for i, path in enumerate(sys.path):
    print(f"  {i}: {path}")

# Set multiprocessing start method for vLLM workers
os.environ["VLLM_WORKER_MULTIPROC_METHOD"] = "spawn"

# Load hotreload safely
try:
    import hotreload
except Exception as e:
    print(f"[sitecustomize] hotreload import failed: {e}")

# Remove /tmp from sys.path to avoid shadowing internal modules
# sys.path = [p for p in sys.path if p != "/tmp"]

# Unset PYTHONPATH to prevent child processes from inheriting /tmp
# os.environ.pop("PYTHONPATH", None)

print(f"[sitecustomize] sitecustomize completed, sys.path and PYTHONPATH cleaned up.")

