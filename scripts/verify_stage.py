#!/usr/bin/env python3
"""verify_stage.py - POST-stage tree verify (runs after /app/tabby is populated)."""
import sys
from pathlib import Path

fails = []
for name, path, kind in [
    ("main.py staged", "/app/tabby/main.py", "file"),
    ("common/ staged", "/app/tabby/common", "dir"),
    ("endpoints/ staged", "/app/tabby/endpoints", "dir"),
    ("entrypoint present", "/app/tabby/tabby-entry.sh", "file"),
]:
    p = Path(path)
    okn = p.is_file() if kind == "file" else p.is_dir()
    print(f"  {'OK  ' if okn else 'FAIL  '}{name}")
    if not okn:
        fails.append(name)
if fails:
    print(f"STAGE VERIFY FAILED: {fails}")
    sys.exit(1)
print("STAGE VERIFY: ALL OK")