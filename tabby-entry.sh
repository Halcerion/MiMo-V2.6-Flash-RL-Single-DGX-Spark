#!/usr/bin/env bash
# tabby-entry.sh — inside-container launcher for Halcerion's MiMo-V2.6-Flash-RL kit.
# Mounts (all bind mounts, set by start.sh):
#   /models/main   -> pack (MiMo-V2.6-Flash-RL-exl3 minus dflash/, dflash-bf16/, eval/)
#   /models/draft  -> dflash/ drafter, 4bpw (pack card: use this one)
#   /app/tabby/config.yml -> generated from host .env by scripts/config2yml.py
set -euo pipefail

: "${PORT:=8893}"
: "${HOST:=0.0.0.0}"
: "${API_KEY:=}"          # default OFF in-container; start.sh refuses to publish externally without one
: "${DRAFT_MODE:=model}"  # 'model' = DFlash drafter | 'mtp' = MTP heads | 'raw' = none
: "${VISION:=1}"
: "${MAX_SEQ_LEN:=262144}"
: "${CACHE_MODE:=FP16}"
: "${THINKING:=1}"
: "${SERVED_NAME:=MiMo-V2.6-Flash-RL}"

CFG=/app/tabby/config.yml

if [ ! -f "$CFG" ]; then
  echo "[halcerion-kit] FATAL: config.yml not generated (start.sh mounts it at /app/tabby/config.yml)" >&2
  exit 64
fi

# Fix #11 companion for bare `docker run` (start.sh does this via mount):
# auth reads ONLY api_tokens.yml in CWD. Seed it here if missing and an API_KEY
# (or its TABBY_API_KEY alias) is provided, instead of letting the server mint
# random keys nobody holds. NOTE: TABBY_API_KEY is NOT read by TabbyAPI itself
# (env mapping is TABBY_<SECTION>_<FIELD>); the start.sh path is authoritative.
if [ ! -f /app/tabby/api_tokens.yml ] && [ -n "${API_KEY:-}" ]; then
  python3 - "$API_KEY" <<'PYEOF'
import secrets, sys
with open("/app/tabby/api_tokens.yml", "w") as f:
    f.write(f"api_key: {sys.argv[1]}\nadmin_key: {secrets.token_hex(16)}\n")
print("[halcerion-kit] seeded /app/tabby/api_tokens.yml from API_KEY env")
PYEOF
fi

# Runtime CUDA gate — the driver-wedge lesson (9/19) enforced where --gpus all
# actually applies: nvidia-smi healthy is NOT proof the CUDA interface works;
# a real torch init is. Fail fast here (seconds) instead of deep in model load.
if ! python3 -c "
import torch
assert torch.cuda.is_available(), 'CUDA not live at RUNTIME — driver-wedge lesson: reboot before any toolkit surgery'
print('runtime CUDA OK:', torch.cuda.get_device_name(0))
"; then
  exit 70
fi

ARGS=(--host "$HOST" --port "$PORT")

echo "[halcerion-kit] launching TabbyAPI from tree at /app/tabby: model=$SERVED_NAME draft=$DRAFT_MODE vision=$VISION ctx=$MAX_SEQ_LEN"
# NOTE: tabbyAPI ships NO importable module (py-modules = [] upstream); the working
# tree is the app. main.py + common/ + endpoints/ must be present (Dockerfile puts
# the tree here). If they're missing the image build is wrong, not this launcher.
test -f /app/tabby/main.py || { echo "FATAL: /app/tabby/main.py missing from image — rebuild with current Dockerfile" >&2; exit 65; }
exec python3 main.py "${ARGS[@]}"