#!/usr/bin/env python3
"""config2yml.py — generate TabbyAPI config.yml from halcerion-kit .env settings.

Env consumed (defaults): HOST, PORT, API_KEY, SERVED_NAME, MAX_SEQ_LEN,
CACHE_MODE, CHUNK_SIZE, MAX_BATCH_SIZE, DRAFT_MODE, VISION, THINKING,
REASONING_START, REASONING_END.

Inside the container, model_dir/draft dirs are fixed mount points; on the
host (dry-run for validation) paths are as-is. Writes to stdout (dry) or
to path given by argv[1].
"""
import os
import sys

def env(k, d):
    return os.environ.get(k, d)

def ybool(b):
    return "true" if b.lower() in ("1", "true", "yes", "on") else "false"

# In-container bind is ALWAYS 0.0.0.0 (audit): who may reach the port is
# decided by docker -p on the host side, not by TabbyAPI config. Writing the
# host HOST=... here caused config-vs-binding mismatches that broke the
# health probe while the container believed it was fine.
IN_CONTAINER_HOST = "0.0.0.0"
PORT = env("PORT", "8893")
API_KEY = env("API_KEY", "")
SERVED_NAME = env("SERVED_NAME", "MiMo-V2.6-Flash-RL")
MAX_SEQ_LEN = env("MAX_SEQ_LEN", "262144")
CACHE_MODE = env("CACHE_MODE", "FP16")
CHUNK_SIZE = env("CHUNK_SIZE", "2048")
MAX_BATCH_SIZE = env("MAX_BATCH_SIZE", "1")
DRAFT_MODE = env("DRAFT_MODE", "model")   # 'model' (DFlash) | 'mtp' | 'raw'
VISION = ybool(env("VISION", "1"))
THINKING = ybool(env("THINKING", "1"))

# Pack author's card: thinking-mode markers for this checkpoint (the card's
# reasoning:true example). Overridable via REASONING_START/REASONING_END if
# upstream revises them.
REASONING_START = env("REASONING_START", '<think>')
REASONING_END = env("REASONING_END", '</think>')

model_block = f"""model:
  model_dir: /models
  model_name: main
  max_seq_len: {MAX_SEQ_LEN}
  cache_size: {MAX_SEQ_LEN}
  cache_mode: {CACHE_MODE}
  chunk_size: {CHUNK_SIZE}
  max_batch_size: {MAX_BATCH_SIZE}
  thinking: {THINKING}
"""

if VISION == "true":
    model_block += "  vision: true\n"

draft_block = ""
if DRAFT_MODE == "model":
    draft_block = f"""draft_model:
  draft_mode: model
  draft_model_dir: /models
  draft_model_name: draft
  draft_cache_mode: {CACHE_MODE}
  dynamic_draft: true
"""
elif DRAFT_MODE == "mtp":
    draft_block = f"""draft_model:
  draft_mode: mtp
  dynamic_draft: true
"""
elif DRAFT_MODE == "raw":
    # no drafter: main model only (single-stream decode measurement lane)
    draft_block = ""
else:
    print(f"# WARNING: unknown DRAFT_MODE={DRAFT_MODE!r}, skipping draft block", file=sys.stderr)

network_block = f"""network:
  host: {IN_CONTAINER_HOST}
  port: {PORT}
"""
# Fix #11 (verified upstream main common/auth.py): TabbyAPI auth reads ONLY
# api_tokens.yml in the tree CWD — network.api_key is NOT a NetworkConfig
# field, and this file must never reintroduce it. The keystore is seeded and
# mounted read-only by start.sh (tabby-entry.sh has a bare-docker fallback).

# Upstream-verified (TabbyAPI repo, main): preset lives at
# sampler_overrides/safe_defaults.yml; values temp 0.8 / top_k 40 / top_p 0.95 /
# min_p 0.05, each force:false (only fills params the CLIENT omits). Kills the
# "No sampler overrides are configured" warning and stops bare/naive requests
# from running at temperature 1.0 / top_k 0 / top_p 1.0 untruncated.
sampling_block = """sampling:
  override_preset: safe_defaults
"""

out = model_block + draft_block + sampling_block + network_block

if len(sys.argv) > 1:
    with open(sys.argv[1], "w") as f:
        f.write(out)
    print(f"[config2yml] wrote {sys.argv[1]}", file=sys.stderr)
else:
    print(out)