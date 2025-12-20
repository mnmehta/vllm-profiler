import traceback
from functools import wraps
def my_decorator(func):
    @wraps(func)  # Preserves metadata of the original function
    def wrapper(*args, **kwargs):
        if not hasattr(wrapper,"count"):
            wrapper.count = 0
        wrapper.count += 1
        print(f"{wrapper.count}: Calling {func.__name__} with args: {args}, kwargs: {kwargs}")
        #traceback.print_stack()
        result = func(*args, **kwargs)
        print(f"{func.__name__} returned: {result}")
        return result
    return wrapper

def wrap_func_with_profiler(original_func):

    import torch
    import os
    import functools
    count=0
    from torch.profiler import profile, record_function, ProfilerActivity
    prof = profile(activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA], record_shapes=True, with_stack=True)
    start_profile = 100
    steps = 50
    @functools.wraps(original_func)
    def wrapped_func(*args, **kwargs):
        nonlocal count, prof , start_profile, steps
        count += 1
        if count == start_profile:
            print("Starting profiler")
            prof.start()
        if count == start_profile + steps:
            print("stopping profiler")
            prof.stop()
            print(prof.key_averages().table(sort_by="cuda_time_total", row_limit=50))
            prof.export_chrome_trace(os.getenv("VLLM_TORCH_PROFILE","trace" + str(os.getpid()) + ".json"))
        print(f"Calling with args: {args}, kwargs: {kwargs} count {count}")
        result = original_func(*args, **kwargs)
        print(f"returned: {result}")
        return result
    return wrapped_func

def print_pid_and_gpu():
  import os
  import torch
  from vllm.v1.worker.gpu_worker import logger
  #For some reason this always gives gpu 0 is vllm, need to use multiprocessing.get_tp_group
  logger.info(f"pid {os.getpid()} gpu {torch.cuda.current_device()}")

def wrap_function():
  import vllm.v1.worker.gpu_worker
  print("wrapping")
  print(vllm.v1.worker.gpu_worker.Worker.execute_model.__wrapped__)
  vllm.v1.worker.gpu_worker.Worker.execute_model = wrap_func_with_profiler(vllm.v1.worker.gpu_worker.Worker.execute_model)

def unwrap_function():
  import vllm.v1.worker.gpu_worker
  vllm.v1.worker.gpu_worker.Worker.execute_model = vllm.v1.worker.gpu_worker.Worker.execute_model.__wrapped__

def safe_wrap_function():
    try:
        wrap_function()
    except Exception as e:
        print(f"[wrap] suppressed fatal error: {e}")



safe_wrap_function()
