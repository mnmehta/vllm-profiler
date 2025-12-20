import sys
import importlib
import importlib.util
import importlib.abc

class PostImportLoader(importlib.abc.Loader):
    def __init__(self, loader):
        self.loader = loader

    def create_module(self, spec):
        if hasattr(self.loader, "create_module"):
            return self.loader.create_module(spec)
        return None

    def exec_module(self, module):
        self.loader.exec_module(module)
        print(f"{module.__name__} loaded")

class PostImportFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if fullname != "vllm.v1.worker.gpu_worker.Worker":
            return None

        # Prevent recursive lookup
        sys.meta_path.remove(self)
        try:
            spec = importlib.util.find_spec(fullname)
        finally:
            sys.meta_path.insert(0, self)

        if spec and spec.loader:
            spec.loader = PostImportLoader(spec.loader)
            return spec
        return None

sys.meta_path.insert(0, PostImportFinder())

import pandas

