#!/usr/bin/env python3
"""gen_tabby_deps.py - export TabbyAPI's Python deps (pyproject-only) to a requirements file.

TabbyAPI declares deps ONLY in pyproject.toml's dependencies array (verified:
no requirements.txt exists in the repo). exllamav3/torch/uvloop/winloop lines
are stripped: exllamav3 comes from our aarch64 source build, torch from the
NVCR base, uvloop installed separately with an aarch64 wheel.
"""
from pathlib import Path
import tomllib

pp = tomllib.loads(Path("/builds/tabbyAPI/pyproject.toml").read_text())
deps = pp["project"]["dependencies"]
strip = ("exllamav3", "torch", "uvloop", "winloop")
keep = [d for d in deps if not any(s in d for s in strip)]
out = "\n".join(keep)
Path("/builds/tabbyAPI/requirements.generated.txt").write_text(out)
print(f"generated requirements.generated.txt with {len(keep)} deps (stripped {len(deps)-len(keep)} markers)")
print("deps:", keep)
