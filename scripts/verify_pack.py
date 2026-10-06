#!/usr/bin/env python3
"""verify_pack.py - post-download completeness gate (runs BEFORE any load cycle).

Flight-5 lesson: a bad pack costs a ~9-minute main-model load cycle to
discover (crash at drafter config after 525s of loading). Verifying what the
download actually created (not what we hope it did, not host-side hopes about
symlinks) takes ~2s with stdlib. Checks:

  1. main model: model.safetensors.index.json parses; every shard it references
     exists with real content (a silent missing/zero shard would crash the
     load exactly like flight 5's drafter did).
  2. tokenizer + aux files that TabbyAPI/Tokenizer touch at container create.
  3. drafter: dflash/config.json + dflash/model.safetensors with real sizes
     (a ~135-byte LFS pointer left by an interrupted download fails this).

Sizes are lower bounds well above any LFS pointer file; exact sizes drift as
the pack author republishes, so nothing is asserted exactly.

Usage: verify_pack.py <pack_dir>    (exit 0 = safe to load, 1 = named missing files)
"""
import json
import os
import sys

FILE_NOT_FOUND = []

# (relative path, minimum plausible size in bytes, what it is)
EXPECTED = [
    ("model.safetensors.index.json", 500_000, "shard index"),
    ("quantization_config.json", 1_000_000, "per-tensor storage record"),
    ("config.json", 1_000, "main model config"),
    ("generation_config.json", 100, "generation config"),
    ("tokenizer.json", 1_000_000, "tokenizer"),
    ("tokenizer_config.json", 1_000, "tokenizer config"),
    ("vocab.json", 1_000_000, "vocab"),
    ("merges.txt", 500_000, "merges"),
    ("chat_template.jinja", 500, "chat template"),
    # vision + custom-arch helpers the pack ships for TabbyAPI/exl3
    ("preprocessor_config.json", 100, "vision preprocessor config"),
    ("modeling_mimo_v2.py", 10_000, "custom arch code"),
    ("configuration_mimo_v2.py", 1_000, "custom arch config"),
    # drafter (pack card: "dflash/ - use this one")
    ("dflash/config.json", 500, "drafter config"),            # real 1,674 B; LFS pointer ~135 B
    ("dflash/model.safetensors", 10_000_000, "drafter weights"),  # real ~735 MB
    ("dflash/quantization_config.json", 10_000, "drafter quant record"),
]


def fail(msgs, hint):
    for m in msgs:
        print(f"  \u2717 {m}")
    print(f"\n  fix: re-run ./start.sh after ensuring '{hint}' completed; see README troubleshooting")
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: verify_pack.py <pack_dir>")
    pack = sys.argv[1]
    idx_abs = os.path.join(pack, "model.safetensors.index.json")

    if not os.path.isfile(idx_abs) or os.path.getsize(idx_abs) == 0:
        fail([f"{idx_abs} missing or empty - download did not complete"], "pack download")
    idx = None
    try:
        with open(idx_abs) as f:
            idx = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        fail([f"index unreadable: {e}"], "pack download")
    if idx is None:
        fail(["index could not be loaded"], "pack download")

    shards = sorted(set(idx.get("weight_map", {}).values()))
    if not shards:
        fail(["index has an empty weight_map"], "pack download")

    total = 0
    missing, dead = [], []
    for shard in shards:
        p = os.path.join(pack, shard)
        if not os.path.isfile(p):
            missing.append(f"missing shard: {shard}")
            continue
        n = os.path.getsize(p)
        if n <= 0:
            dead.append(f"zero-byte shard: {shard}")
        else:
            total += n

    if missing or dead:
        fail(missing + dead, "pack download (shards)")

    gi = total / (1 << 30)
    print(f"  \u2713 main model: {len(shards)} shards present, {gi:.1f} GiB")

    problems = []
    for rel, min_size, what in EXPECTED:
        if rel == "model.safetensors.index.json":
            continue  # already checked along with every shard it references
        p = os.path.join(pack, rel)
        if not os.path.isfile(p):
            problems.append(f"missing {what}: {rel}")
            continue
        n = os.path.getsize(p)
        if n < min_size:
            problems.append(
                f"{rel} too small ({n:,} B; expected >= {min_size:,}) - possible LFS pointer or truncated download"
            )
    if problems:
        fail(problems, "pack download")

    n_checked = len(EXPECTED) - 1 + len(shards)
    print(f"  \u2713 drafter: dflash/ complete (config + weights + quant record)")
    print(f"  STAGE VERIFY: ALL OK - {n_checked} files over {gi:.1f} GiB")


if __name__ == "__main__":
    main()