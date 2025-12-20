import threading
import importlib.util
import sys
import os
import time
from types import ModuleType
from typing import Optional, Callable

# --- Safe profiler loader ---
def load_module_from_file(file_path: str) -> Optional[ModuleType]:
    """
    Dynamically load a module from the specified file.
    Returns None on failure, does not raise exceptions.
    """
    try:
        if not os.path.isfile(file_path):
            return None

        module_name = os.path.splitext(os.path.basename(file_path))[0]
        spec = importlib.util.spec_from_file_location(module_name, file_path)
        if spec is None or spec.loader is None:
            return None

        hot_module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = hot_module
        spec.loader.exec_module(hot_module)

        os.write(1, f"Loaded module {module_name} from {file_path}\n".encode())
        return hot_module

    except Exception as e:
        os.write(2, f"Module load failed for {file_path}: {e}\n".encode())
        return None


# --- Hot-reload wrapper ---
def hot_reload_wrapper(file_path: str, reload_interval: float = 1.0) -> Callable[[], Optional[ModuleType]]:
    """
    Returns a callable that provides the latest version of the profiler module.
    Hot-reloads every `reload_interval` seconds if:
      - File exists
      - vLLM GPU worker is already imported
      - File has never been loaded or has changed
    """
    module: Optional[ModuleType] = None
    last_mod_time: float = 0.0

    try:
        if os.path.isfile(file_path):
            last_mod_time = os.path.getmtime(file_path)
    except OSError:
        last_mod_time = 0.0

    def updater():
        nonlocal module, last_mod_time
        while True:
            try:
                # Only load if the file exists and GPU worker has been imported
                if os.path.isfile(file_path) and "vllm.v1.worker.gpu_worker" in sys.modules:
                    current_mod_time = os.path.getmtime(file_path)

                    # First time load or file updated
                    if module is None or current_mod_time > last_mod_time:
                        new_module = load_module_from_file(file_path)
                        if new_module is not None:
                            module = new_module
                            last_mod_time = current_mod_time
                            os.write(1, f"Reloaded module from {file_path}\n".encode())

            except Exception as e:
                os.write(2, f"Hot-reload error: {e}\n".encode())

            time.sleep(reload_interval)

    # Start hot-reload thread
    thread = threading.Thread(target=updater, daemon=True)
    thread.start()

    # Return callable to access the current module
    def wrapper() -> Optional[ModuleType]:
        return module

    return wrapper


# --- Usage ---
hot_module_loader = hot_reload_wrapper(
    os.getenv("RELOAD", "/home/vllm/profiler.py"),
    reload_interval=1.0
)

