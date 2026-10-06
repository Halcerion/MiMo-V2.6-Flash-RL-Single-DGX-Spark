#!/usr/bin/env bash
# stop.sh — stop the halcerion mimo container and free the GPU memory.
set -euo pipefail
cd "$(dirname "$0")"
# .env supplies CONTAINER_NAME and PORT here (fix #9: without sourcing it,
# probes used the script's own fallback and checked the wrong port whenever
# .env changed it).
if [ -f .env ]; then
  set -a; source .env; set +a
fi
NAME="${CONTAINER_NAME:-halcerion-mimo-spark}"

if ! docker ps -q -f name=^${NAME}$ | grep -q .; then
  echo "[halcerion-kit] not running"
  exit 0
fi

# In-flight handling (upstream-verified, tabbyAPI common/health.py +
# endpoints/core/types/health.py): /health returns {status, issues} ONLY —
# there is no busy/in-flight field and no endpoint to query active
# generations, so there is nothing honest to probe here. Instead docker stop
# sends SIGTERM: uvicorn refuses NEW connections immediately and finishes or
# cuts existing streams during the grace window, then SIGKILL. Run long
# generations from tmux so a stop is always a deliberate act; extend
# STOP_GRACE_S in .env if you need longer to let streams drain.
docker stop -t "${STOP_GRACE_S:-30}" "$NAME" >/dev/null || true
docker rm "$NAME" >/dev/null
echo "[halcerion-kit] stopped; GPU memory freed (verify: nvidia-smi on the spark)"