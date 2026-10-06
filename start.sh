#!/usr/bin/env bash
# start.sh - Halcerion kit: MiMo-V2.6-Flash-RL (EXL3 2.27bpw) on one DGX Spark.
# Pattern credit: MiaAI-Lab's Qwen3.8-Flash-Next-Single-DGX-Spark kits.
# Model pack credit: benthecarman/MiMo-V2.6-Flash-RL-exl3 (built on GB10).
#
# Steps: preflight -> image (pull GHCR else build) -> GPU probe -> download ->
#        config.yml -> launch -> wait healthy -> smoke test -> LIVE banner
# Env/.env: see .env.example. Container name: halcerion-mimo-spark
set -euo pipefail
cd "$(dirname "$0")"

# ---------- config (env wins over .env) ----------
RESTART=0
case "${1:-}" in
  "") ;;
  restart) RESTART=1 ;;
  *) printf 'unknown argument: %s (usage: ./start.sh [restart])\n' "$1" >&2; exit 2 ;;
esac
if [ -f .env ]; then
  set -a; source .env; set +a
fi
PORT="${PORT:-8893}"
HOST="${HOST:-127.0.0.1}"                # loopback default; tailscale/LAN users set HOST=0.0.0.0 + API_KEY
API_KEY="${API_KEY:-}"                   # REQUIRED if publishing beyond loopback (enforced below)
CONTAINER_NAME="${CONTAINER_NAME:-halcerion-mimo-spark}"
IMAGE="${IMAGE:-ghcr.io/halcerion/mimo-v2.6-flash-rl-single-dgx-spark:latest}"
PACK_REPO="${PACK_REPO:-benthecarman/MiMo-V2.6-Flash-RL-exl3}"
PACK_DIR="${PACK_DIR:-$HOME/.cache/halcerion/mimo-v2.6-flash-rl-exl3}"
HF_TOKEN_FILE="${HF_TOKEN_FILE:-$HOME/.cache/huggingface/token}"
DRAFT_MODE="${DRAFT_MODE:-model}"
VISION="${VISION:-1}"
MAX_SEQ_LEN="${MAX_SEQ_LEN:-262144}"
SERVED_NAME="${SERVED_NAME:-MiMo-V2.6-Flash-RL}"   # informational only; real API id comes from /v1/models
NEED_HOST_GIB="${NEED_HOST_GIB:-70}"     # MemAvailable gate before launch
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-1800}" # cold load ~10min; author saw 15GiB spare at ctx

# ---------- helpers ----------
step()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m  \u2713 %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
info()  { printf '\033[1;34m  i %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m  \u2717 %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }

# ---------- 1. preflight ----------
step "1/6 Preflight"
command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (group? nvidia runtime?)"
FREE_GIB=$(awk '/MemAvailable/ {printf "%.1f", $2/1048576}' /proc/meminfo)
# Enforced gate (unified-memory box: a CUDA OOM freezes the whole machine, so
# we refuse launches below the water line instead of discovering OOM by freeze).
# NEED_HOST_GIB covers HOST-side headroom only (other processes, page cache);
# the pack + KV pool budget inside the container is separate and validated by
# the disk gate in step 3 + the model's own allocation at load.
if awk -v f="$FREE_GIB" -v n="$NEED_HOST_GIB" 'BEGIN { exit !(f < n) }'; then
  die "MemAvailable ${FREE_GIB} GiB < required ${NEED_HOST_GIB} GiB — something else is holding memory (another model? stop it first with ./stop.sh or docker stop). Override: NEED_HOST_GIB=<N> in .env" 3
fi
ok "MemAvailable: ${FREE_GIB} GiB (gate: ${NEED_HOST_GIB} GiB)"
if docker ps --format '{{.Names}}' | grep -v "^${CONTAINER_NAME}$" | grep -q .; then
  warn "other containers running - one-model-at-a-time rule; stop.sh them first if they hold GPU"
  docker ps --format '    {{.Names}} ({{.Image}})'
fi
if [ "$HOST" != "127.0.0.1" ] && [ -z "$API_KEY" ]; then
  die "HOST != loopback without API_KEY - refuse to publish an unauthd GPU to the LAN/tailnet (our 9/19 lesson). Set API_KEY in .env"
fi

# ---------- 2. image ----------
step "2/6 Image"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "image present"
elif docker pull "$IMAGE" >/dev/null 2>&1; then
  ok "pulled prebuilt GHCR image"
else
  warn "GHCR image unavailable - building locally (exllamav3 aarch64 source build, several minutes)"
  docker build --build-arg EXL3_REF="${EXL3_REF:-v1.5.2}" -t "$IMAGE" .
  ok "built"
fi
# GPU proof - run AFTER image presence is guaranteed. (Audit finding: preflight
# probed before the image existed, so on flight 1 the driver-wedge check
# silently never ran, defeating its fail-fast purpose.)
if ! docker run --rm --gpus all --entrypoint python3 "$IMAGE" -c "import torch; assert torch.cuda.is_available()" >/dev/null 2>&1; then
  die "GPU probe failed with image present - CUDA interface dead; driver-wedge rule: REBOOT before toolkit surgery (9/19 lesson)"
fi
ok "GPU probe: CUDA live in container"

# ---------- 3. checkpoint ----------
step "3/6 Checkpoint (~85 GiB, resumable)"
# NOTE: the pack dir may not exist yet - check its nearest existing ancestor so
# we measure the real filesystem the pack will land on, not a nonexistent one.
DISK_PATH="$PACK_DIR"
while [ ! -d "$DISK_PATH" ] && [ "$DISK_PATH" != "/" ]; do
  DISK_PATH="$(dirname "$DISK_PATH")"
done
DISK_FREE=$(df -BG "$DISK_PATH" 2>/dev/null | tail -1 | awk '{print $4}' | tr -dc '0-9')
if [ -z "$DISK_FREE" ] || [ "$DISK_FREE" -lt 90 ]; then
  die "only ${DISK_FREE:-?}G free on $(df "$DISK_PATH" 2>/dev/null | tail -1 | awk '{print $1}') - need ~90G for the pack"
fi
warn "disk gate: ${DISK_FREE}G free on ${DISK_PATH}"
if [ ! -f "$PACK_DIR/model.safetensors.index.json" ]; then
  if command -v hf >/dev/null; then
    hf download "$PACK_REPO" --local-dir "$PACK_DIR" \
      --exclude "dflash-bf16/*" \
      --exclude "eval/*"
  else
    docker run --rm -v "$PACK_DIR:/out" -v "$HOME/.cache/huggingface:/hf" \
      "$IMAGE" python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('$PACK_REPO', local_dir='/out', exclude=['dflash-bf16/*','eval/*'])
"
  fi
fi
[ -f "$PACK_DIR/model.safetensors.index.json" ] || die "pack incomplete after download"
ok "pack ready at $PACK_DIR"

# Completeness gate: every indexed shard + tokenizer + drafter files real and
# non-truncated BEFORE the first ~9-minute load cycle pays for a bad file.
# (Flight 5: a dangling drafter staged via host-side symlinks cost a full
# cold-load cycle to discover; this gate would have caught it in ~2s.)
python3 scripts/verify_pack.py "$PACK_DIR"

# ---------- 4. config.yml ----------
step "4/6 Generate config.yml"
GENERATED=$(mktemp /tmp/halcerion-config.XXXXXX.yml)
PORT="$PORT" API_KEY="$API_KEY" SERVED_NAME="$SERVED_NAME" \
MAX_SEQ_LEN="$MAX_SEQ_LEN" DRAFT_MODE="$DRAFT_MODE" VISION="$VISION" \
  python3 scripts/config2yml.py "$GENERATED"
ok "config generated"

# ---------- 4b. auth keystore (fix #11) ----------
# Verified upstream main common/auth.py: TabbyAPI reads auth from ONLY
# api_tokens.yml in the tree CWD (mints random keys if the file is missing,
# watcher-reloads on change). network.api_key is not a NetworkConfig field and
# TABBY_API_KEY maps to no field — both silently orphaned $API_KEY on every
# previous flight. Seed the keystore host-side, persist it beside .env, mount
# read-only into the tree CWD (read-only is watcher-safe).
KEYSTORE="${KEYSTORE:-$PWD/api_tokens.yml}"
KEYSTORE_MOUNT=()
if [ -n "$API_KEY" ]; then
  if [ ! -f "$KEYSTORE" ]; then
    ADMIN_KEY=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf 'api_key: %s\nadmin_key: %s\n' "$API_KEY" "$ADMIN_KEY" > "$KEYSTORE"
    chmod 600 "$KEYSTORE"
    ok "auth keystore seeded at $KEYSTORE (api_key from .env; delete file to rotate)"
  else
    ok "auth keystore present at $KEYSTORE"
  fi
  KEYSTORE_MOUNT=(-v "$KEYSTORE:/app/tabby/api_tokens.yml:ro")
fi

# ---------- 5. launch ----------
step "5/6 Launch"
if [ "$(docker ps -q -f name=^${CONTAINER_NAME}$)" ]; then
  if [ "$RESTART" = "1" ]; then
    # ./start.sh restart = stop + remove + relaunch with the CURRENT .env
    # (documented behavior: switching DRAFT_MODE / VISION / port takes effect
    # on re-run, not just "already running, bye"). stop.sh's busy-check is
    # deliberately not honored here: restart is an explicit operator action.
    warn "restart: stopping current container"
    docker stop -t 30 "$CONTAINER_NAME" >/dev/null
    docker rm "$CONTAINER_NAME" >/dev/null
    ok "stopped; relaunching below with current settings"
  else
    warn "already running; use ./start.sh restart to apply new settings"
    exit 0
  fi
fi
# Reachability decided HERE by the -p host-bind (audit finding: HOST_BIND was a
# fictional variable - the container published 0.0.0.0:8893 even with
# HOST=127.0.0.1 in .env, voiding the API-key guard).
# Drafter = the pack's OWN dflash/ dir, bind-mounted read-only where TabbyAPI
# expects a drafter dir (its config joins draft_model_dir + draft_model_name).
# Never stage this via host-side symlinks: they dangle inside the container
# (flight 5, FileNotFoundError /models/draft/config.json after a full
# 525s cold load). Real pack files can't dangle.
docker run -d --name "$CONTAINER_NAME" \
  --gpus all \
  --shm-size 4g \
  -p "${HOST}:${PORT}:${PORT}" \
  -v "$GENERATED:/app/tabby/config.yml:ro" \
  "${KEYSTORE_MOUNT[@]}" \
  -v "$PACK_DIR:/models/main:ro" \
  -v "$PACK_DIR/dflash:/models/draft:ro" \
  -e PORT="$PORT" -e API_KEY="$API_KEY" \
  -e DRAFT_MODE="$DRAFT_MODE" -e SERVED_NAME="$SERVED_NAME" \
  -e MAX_SEQ_LEN="$MAX_SEQ_LEN" -e VISION="$VISION" \
  --restart unless-stopped \
  "$IMAGE" >/dev/null
ok "container started"

# ---------- 6. health + smoke ----------
step "6/6 Health + smoke test"
ELAPSED=0
while true; do
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo 000)
  if [ "$HTTP" = "200" ]; then ok "healthy after ${ELAPSED}s"; break; fi
  # Dead-container detection (audit finding: a Restart-loop from a bad config.yml
  # used to stall the full 30-min health timeout before any logs appeared).
  STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo gone)
  if [ "$STATUS" != "running" ] && [ "$ELAPSED" -gt 30 ]; then
    docker logs --tail 40 "$CONTAINER_NAME" 2>&1 || true
    die "container status: $STATUS (not running) after ${ELAPSED}s - logs above"
  fi
  if [ "$ELAPSED" -ge "$HEALTH_TIMEOUT" ]; then docker logs --tail 40 "$CONTAINER_NAME"; die "health timeout"; fi
  sleep 15; ELAPSED=$((ELAPSED+15)); printf '  ...loading %ds\n' "$ELAPSED"
done

AUTH=()
[ -n "$API_KEY" ] && AUTH=(-H "Authorization: Bearer ${API_KEY}")
# Discover the model id TabbyAPI actually serves (audit finding: SERVED_NAME was
# invented by us; TabbyAPI reports its config's model id - commonly the dir name
# - and a wrong id 404s the smoke test even with a healthy server).
MODELS_JSON=$(curl -s "http://127.0.0.1:${PORT}/v1/models" "${AUTH[@]}")
MODEL_ID=$(printf '%s' "$MODELS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || true)
if [ -z "$MODEL_ID" ]; then
  printf '%s' "$MODELS_JSON" | head -c 400; echo
  die "could not read /v1/models - cannot determine model id for smoke test"
fi
info "serving model id: $MODEL_ID"
RESP=$(curl -s "http://127.0.0.1:${PORT}/v1/chat/completions" "${AUTH[@]}" \
  -H 'Content-Type: application/json' -d '{
  "model": "'"$MODEL_ID"'",
  "messages": [{"role":"user","content":"Reply with exactly: HALCERION-KIT-OK"}],
  "max_tokens": 400}')
echo "$RESP" | grep -q "HALCERION-KIT-OK" || { echo "$RESP" | head -c 600; die "smoke test failed"; }
ok "smoke test passed"

# Fix #15: box glyphs via printf \uHHHH escapes. The old <<BANNER heredoc did
# NOT interpret \uXXXX (heredocs are literal text; only printf/echo -e process
# them), so the banner shipped as visible escape soup. printf format strings
# interpret \uHHHH (bash >= 4.2); %-*.*s pads/truncates dynamic lines so the
# right wall stays aligned no matter how long the endpoint/model strings are.
# Fix #15b (banner-execute test found it): util-linux hostname (Arch) rejects
# -I while net-tools (Spark's Ubuntu) accepts it - a silent-empty IP otherwise.
# Prefer the kernel's routed source address (iproute2, universal), fall back.
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
[ -z "$IP" ] && IP=$(hostname -I 2>/dev/null | awk '{print $1}')
BAR=$(printf '\u2550%.0s' $(seq 1 54))
printf '\n'
printf '  \u2554%s\u2557\n' "$BAR"
printf '  \u2551 %-*.*s \u2551\n' 52 52 "MiMo-V2.6-Flash-RL is LIVE"
printf '  \u2551 %-*.*s \u2551\n' 52 52 "endpoint:  http://${IP}:${PORT}/v1"
printf '  \u2551 %-*.*s \u2551\n' 52 52 "model:     ${MODEL_ID}"
printf '  \u2551 %-*.*s \u2551\n' 52 52 "draft:     ${DRAFT_MODE}   vision: ${VISION}   ctx: ${MAX_SEQ_LEN}"
printf '  \u2551 %-*.*s \u2551\n' 52 52 "container: ${CONTAINER_NAME}"
printf '  \u255a%s\u255d\n' "$BAR"
echo "  ./stop.sh stops it.  tools/bench.py measures it (pass --model \"$MODEL_ID\")."

# FOREGROUND=1: stay attached following container logs (systemd unit shape:
# Type=simple wrapper stays alive while the server runs; container keeps
# running across a Ctrl-C of this follower thanks to --restart unless-stopped).
if [ "${FOREGROUND:-0}" = "1" ]; then
  info "FOREGROUND=1: following container logs (Ctrl-C to detach; container keeps running)"
  exec docker logs -f --tail 0 "$CONTAINER_NAME"
fi
