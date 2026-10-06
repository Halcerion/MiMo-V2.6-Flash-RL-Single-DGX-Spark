# Flight Report — MiMo-V2.6-Flash-RL on DGX Spark (Halcerion kit)

Status: **FLIGHT 7 LIVE + SMOKE GREEN** (2026-09-30 ~21:25 CDT). Bench sections
fill as tools/bench.py output lands; results/ appends automatically.

## Environment
- Host: DGX Spark (GB10), workdir ~/Programs/MiMo-V2.6-Flash-RL-Single-DGX-Spark
- MemAvailable at preflight: 118.4 GiB (gate: 70)
- Disk at gate: 2926 GiB free (gate: 90)
- Image: built locally (GHCR pending publish), nvcr pytorch 26.07-py3 + exllamav3 v1.5.2 + TabbyAPI main
- CUDA probe in container: PASS (GB10 visible)

## Build history (11 fixes, all flight-verified)
| # | Flight | Symptom | Root cause | Fix |
|---|--------|---------|-----------|-----|
| 1 | 1 | pip root warning noise | missing --root-user-action | . root-action everywhere |
| 2 | 1 | ModuleNotFoundError tabby_api / no exllamav3.__version__ | TabbyAPI ships no module (py-modules=[]); __version__ None by design | verify via importlib.metadata; run tree main.py |
| 3 | 2 | FileNotFoundError requirements.txt | deps live only in pyproject | tomllib-generated requirements.generated.txt |
| 4 | 3 | IndentationError <stdin> line 11 | heredoc-in-RUN swallowed pip lines into python stdin | standalone script files, no heredocs |
| 5 | 3b | cp: cannot create /app/tabby | NVCR base lacks /app; WORKDIR had implicitly created it in old layout | mkdir -p before cp -a |
| 6 | 3c | disk 0G fabricated | df on nonexistent pack dir + bad df field | walk up to nearest existing ancestor |
| 7 | 4 | resolve/main/eval/%2A 404 | hf CLI took 2nd exclude pattern as positional FILE | --exclude per pattern |
| audit | 4 | +5 ordering/semantic defects (GPU probe pre-image, HOST_BIND fictional, config host conflict, dead-container stall, invented model id) | check-before-create class | commit 4e390bc |
| 8 | 6 | `{"detail":"Invalid API key"}` at /v1/models after "healthy" | literal `***` in the smoke-test AUTH array (placeholder text shipped instead of `$API_KEY`) - server auth works, smoke client sent a fake key | pass real `$API_KEY` in smoke headers (c9f9be3) |
| 9 | 7 | in-flight warning silently dead on PORT≠8893 | stop.sh never sourced .env, probed ${PORT:-8893} instead of the .env PORT | stop.sh sources .env like start.sh (same commit) |
| 10 | 7 | hand recipes (grep\|cut on .env) built keys like `a1b2c3  # REQUIRED if...` → eternal 401 while server key was clean | .env.example placed its comment INLINE on the API_KEY line; source cuts at #, grep doesn't | comments moved off value lines in .env.example; runbook warns (54823ff) |
| 11 | 7 | server banner "Your API key is: a3862aca…" ≠ .env's a1b2c3; every keyed curl 401'd on all flights | VERIFIED upstream main common/auth.py: auth reads ONLY api_tokens.yml (mints random keys if missing). network.api_key is not a NetworkConfig field (pydantic ignores it = dead config line) and TABBY_API_KEY maps to no field — $API_KEY was orphaned end-to-end | start.sh seeds api_tokens.yml host-side (persisted, chmod 600, :ro mount) with entry-script fallback for bare runs; api_key line removed from config gen |
| 12 | 7 | bench died at discovery: HTTP 401 in discover_model on the first keyed run | tools/bench.py built /v1/models discovery request without the Authorization header (api_key never passed in); per-run call() authed fine — sibling-path drift again | discover_model(base_url, api_key) sends Bearer header |
| 13 | 7 | bench lane: 3× `object of type 'NoneType' has no len()` then reporter KeyError | thinking mode (template default) can consume the whole 512-token budget in reasoning → content null at truncation (verified live: enable_thinking:false returns clean 2296-char answer); all-failed lane crashed the summary loop | bench payload defaults thinking OFF (--thinking opts in); null-safe content; records server timings + DFlash accepted/rejected; fail-loud on total failure |
| 14 | 7 | #13's server fields recorded null; toolcall lane had no way to record tool_calls | server timings live inside TabbyAPI's `usage` block (prompt_time, completion_tokens_per_sec…), not a top-level `timings` dict; call() never captured message.tool_calls | server fields read usage; n_tool_calls + tool_call_names captured |
| 15 | 7 | banner printed literal `\u2550` escape soup | `cat <<BANNER` heredoc is literal text — \uXXXX escapes only process inside printf format strings (as the ok/warn helpers already did) | banner rebuilt with printf \uHHHH + %-*.*s padding so the right wall aligns (aaaf426-era flights showed the soup) |
| 15b | 7 | banner endpoint line would silently print `http://:8888/v1` on Arch/util-linux hosts | util-linux hostname rejects `-I` (net-tools accepts it) — caught because the banner-execute test ran on this Arch host first | IP via `ip -4 route get 1.1.1.1` src (iproute2, universal), hostname -I fallback |

## Build history note
15 fixes (+15b), all flight-verified. #8's original verdict ("server auth works") was
wrong — see #11: the server was minting random keys on every flight.

## Smoke test artifacts
- /v1/models id discovered: main (matches banner)
- HALCERION-KIT-OK reply: **PASS — flight 7**, verified twice: start.sh smoke
  (on-Spark) + off-box witness from a second LAN host (health 200 / keyless
  models 401 = auth enforces from LAN / keyed models 200 / completion replied
  HALCERION-KIT-OK exactly; 429 prompt + 29 completion tokens)
- Served meta: size 91,573,061,668 B (85.3 GiB), n_ctx 262,144, n_vocab 152,576

## Model load (fill in live)
- config.yml draft_mode: DFlash (model), vision: 1, ctx: 262144, sampling: safe_defaults preset
- Load time cold: **495s (flight 6)**; warm reload: **35.8s (flight 7)**
- Drafter mounted from pack's own dflash/ dir; STAGE VERIFY: ALL OK
- Peak loader RSS / unified memory: **113 GiB peak (flight 6)**, then flat = all weights + KV resident

## Bench (tools/bench.py; author protocol: greedy temp 0, 512 gen, median of 3)
- DFlash drafted (flight 7, thinking off, off-box client): **coding 46.55 /
  prose 36.1 / reasoning 48.7 / code_edit 34.6** (author: 35-80; code lane 80.7;
  Mia real-world ~35) — acceptance 44-57%, deterministic (std chars 0.0)
- Behavioral (thinking ON, 1024 budget): toolcall 48.0 tok/s, 3/3 single clean
  `get_weather` calls (finish tool_calls); repetition probe 35.5 tok/s, no
  loops, stable 477-528ch outputs, finish=stop (schema-ful multi-call probe
  still pending)
- MTP drafted (DRAFT_MODE=mtp rerun): ___
- Long-ctx decode @64K/250K + prefill tok/s @32k+ (TensorFold comparison): ___
  (author: 16-43) — tiny-prompt prefill datapoint: ~108 tok/s @38 tok
- Tool-call repetition probe (qwen3_coder format, Xiaomi defect watch): no
  repetition observed on any lane
- **Stage D kill criteria: ALL PASS** (coherent ✓ / tool-call 100% ✓ / ≥25
  tok/s ✓ / 262k loads ✓) — supersede-Qwen verdict: operator's call

### Thinking-on rerun (10/1, off-box host, fix #14 timings recorded)
reasoning 55.6 wall / 58.2 server (acceptance 62.0% — vs 48.7/56.9% thinking-off);
code_edit 41.5 / 45.7 (59.5% — vs 34.6/43.7%); prose control 33.2 / 33.9 (48.1% —
thinking HURTS prose, −8%). Verdict: reasoning lane's −20% gap to the card (61.1) was
the thinking-off protocol, not the kit — thinking-on closes to −4.8% server-side
(parity). code_edit residual vs 80.7 is prompt-shape (acceptance ceiling of a short
mixed output; his exact prompt unknown). Wall-vs-server boundary costs 2-9%.
Data: results/bench-thoughtful-flight7.json.

## Publish checklist (after bench lands)
- [ ] results/ committed with this report
- [ ] README numbers updated from data (never hand-typed)
- [ ] Atlas push (HTTPS-only; :2222 closed on droplet)
- [ ] HF dataset card comment on benthecarman pack (deploy confirmed, link kit)
- [ ] GHCR image push from Spark (docker push, ghcr auth)
