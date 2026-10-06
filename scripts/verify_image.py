#!/usr/bin/env python3
"""verify_image.py — post-build sanity for the Halcerion kit image (BUILD-time).

Checks (all possible inside a BuildKit build container):
  - exllamav3 importable; version from distribution metadata (the module
    attribute is None by design: setuptools dynamic = ["version"] zeroes it;
    the real version lives in exllamav3-1.5.2.dist-info METADATA)
  - uvloop + fastapi importable
  - torch import works (NOT cuda availability - build containers don't get a
    GPU unless the builder is specially configured; the runtime entrypoint
    enforces CUDA. Driver-wedge rule lives at RUNTIME, never at build.)

Exits 1 loudly on any failure.
"""
import sys

def check(name, fn):
    try:
        result = fn()
        line = f"  OK  {name}"
        if result is not None:
            line += f"  [{result}]"
        print(line)
        return result
    except Exception as e:
        print(f"  FAIL  {name}: {e}")
        sys.exit(1)

def exl_version():
    from importlib.metadata import version as md_version
    v = md_version("exllamav3")
    major, minor = (int(x) for x in v.split(".")[:2])
    assert (major, minor) >= (1, 5), f"exllamav3 {v} < 1.5.2 (mimo2 support required)"
    return v

def uvloop():
    import uvloop  # noqa: F401

def fastapi():
    import fastapi  # noqa: F401

def torch_import():
    import torch  # noqa: F401
    return torch.__version__

v = check("exllamav3 >= 1.5.x (metadata)", exl_version)
check("uvloop importable", uvloop)
check("fastapi importable", fastapi)
t = check("torch importable (build-time; CUDA enforced at runtime)", torch_import)
print(f"      torch {t}")
print("IMAGE VERIFY (build-time): ALL OK")
print("NOTE: CUDA availability is asserted by the runtime entrypoint, where --gpus all applies.")