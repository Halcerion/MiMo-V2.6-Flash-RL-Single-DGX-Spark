# MiMo-V2.6-Flash-RL on a single DGX Spark — Halcerion deployment kit

One command serves Xiaomi's MiMo-V2.6-Flash-RL (309B total / 15B active MoE, 262k ctx,
text+vision) from one GB10 DGX Spark through an OpenAI-compatible API:

```
git clone https://github.com/halcerion/mimo-v2.6-flash-rl-single-dgx-spark.git
cd mimo-v2.6-flash-rl-single-dgx-spark
cp .env.example .env      # set API_KEY if you want it reachable beyond loopback
./start.sh
```

- Checkpoint: [`benthecarman/MiMo-V2.6-Flash-RL-exl3`](https://huggingface.co/benthecarman/MiMo-V2.6-Flash-RL-exl3)
  (EXL3 2.27 bpw, 85.28 GiB, built and benchmarked on a DGX Spark; DFlash drafter quantized to 4 bpw)
- Engine: TabbyAPI over exllamav3 v1.5.2+ (first stream with the `mimo2` architecture), compiled once
  into our container image so end users never touch a build
- Container: NVIDIA PyTorch base (`nvcr.io/nvidia/pytorch:26.07-py3`), same pattern MiaAI-Lab proved
  for single-Spark kits; weights stay in the host's HF cache and bind-mount read-only
- Drafting: DFlash drafter by default (pack author's faster pick), MTP heads via `DRAFT_MODE=mtp`;
  either can be switched with `./start.sh restart`
- Sampling: TabbyAPI's upstream `safe_defaults` preset (`temp 0.8 / top_k 40 / top_p 0.95 /
  min_p 0.05`) as fallbacks for clients that omit sampling params — bare requests no longer
  run untruncated at temperature 1.0
- Safety rails carried from our own GB10 flight history: `MemAvailable` gate before launch,
  API-key enforcement when bound beyond loopback, no in-container tokens, one-model-at-a-time port map

## Measured (this box, flight 7 — full data in `results/flight-report-2026-09-30.md`)

Protocol mirrors the pack author's Speed table (greedy, batch 1, median of 3, 512
tokens, thinking off, off-box client) so rows are directly comparable:

| lane | pack author (GB10) | ours, thinking off (f7) | ours, thinking on (f7b) |
|---|---|---|---|
| coding, no drafter | 31.5 tok/s | pending (`DRAFT_MODE=raw` rerun) | — |
| coding, DFlash | 49.5 tok/s | 46.55 tok/s | — |
| reasoning, DFlash | 61.1 tok/s | 48.7 tok/s | 55.6 wall / 58.2 server |
| prose, DFlash | 35.4 tok/s | 36.1 tok/s | 33.2 wall / 33.9 server |
| code edit, DFlash | 80.7 tok/s | 34.6 tok/s | 41.5 wall / 45.7 server |
| tool-call JSON (thinking on, 1024 budget) | (unmeasured by author) | — | 3/3 clean calls @ 48.0 wall / 68.4 server |

Author column = the pack card's Speed table, verified against HF 2026-10-01 (his protocol:
exllamav3 v1.5.2, batch 1, greedy, 512 tok, median of 3, decode-loop timing). Verdict
(2026-10-01 rerun, `results/bench-thoughtful-flight7.json`): the reasoning gap was OUR
thinking-off protocol, not the kit — thinking on lifts acceptance 56.9→62.0% and closes
to −4.8% vs the author (parity). code_edit stays −43..-48% with the same handles applied
(acceptance 43.7→59.5%): the residue is prompt-shape — his edit-shaped prompt drafts
better than our short mixed code+prose one — so cross-set comparison tops out here.
Wall-vs-server boundary (TTFT 0.29-0.44 s) costs 2-9%, largest on 5 s completions.
Thinking slightly HURTS prose (−8%): reasoning eats budget, acceptance 53.5→48.1%.
Prefill datapoints this run: 93-154 tok/s at ≤64-token prompts.

Plus lanes the pack author didn't run: tool-call repetition probe (Xiaomi documented a
repetition defect on agentic harnesses; we test what the 2.27bpw quant does) and a
SWE-style diagnosis lane. (Long-context decode datapoints are still open — see the
report's bench table.)

## Why this exists

Two gaps: (1) the pack's own "How to run" is a manual procedure — source
build exllamav3 on aarch64, hand-split directories, hand-write config; (2) no
published single-Spark recipe for MiMo-V2.6-Flash-RL existed. This kit is the
missing one-command path, with the operational lessons of actually running big
models on a 128 GB unified-memory box baked into its gates.

## What start.sh does

1. Preflight: docker + NVIDIA runtime + `MemAvailable` gate (OOM on unified
   memory = whole-machine freeze; we hard-gate instead of hoping)
2. Image: pulls `ghcr.io/halcerion/mimo-...:latest` if published, else builds
   from the Dockerfile (exllamav3 aarch64 source build happens exactly once,
   in the image, never on the deployment target's host Python)
3. Checkpoint: `hf download` (or in-container fallback) of the 85 GiB pack,
   resumable, minus `dflash-bf16/` and `eval/`; then a completeness gate
   (`scripts/verify_pack.py`) validates every indexed shard, tokenizer files
   and the drafter before any load cycle — a bad file costs ~2s here instead
   of a ~9-minute cold-load cycle discovered at crash time (flight 5).
   The drafter is NOT staged or symlinked: the pack's own `dflash/` dir
   bind-mounts read-only at `/models/draft` (host-side symlinks dangle
   inside the container — flight 5's root cause).
4. `config.yml` generated from `.env` (host-side; mounted read-only)
5. Launch + readiness probe (cold load ≈ 10 min) + tool-call smoke test
6. LIVE banner with the actual LAN IP

`./stop.sh` stops it (SIGTERM, graceful for in-flight streams — extend with
`STOP_GRACE_S`); `./start.sh restart`
re-runs with new settings. `FOREGROUND=1 ./start.sh` stays attached (systemd
unit shape).

## Memory budget (why it fits where GGUF Q2_K doesn't)

ggml-org's Q2_K GGUF is 126 GB — over the 121.6 GiB a Spark can actually
address. EXL3 2.27 bpw lands the same model at 85.28 GiB, leaving the pool
ggml's pack can't reach: the pack author measured 15 GiB free with drafter +
vision loaded at full 262,144-context (FP16 cache), 250K prompt. Our
`NEED_HOST_GIB=70` gate refuses launches below measured-safe water lines
instead of discovering OOM by freezing the box.

## Requirements

- DGX Spark (GB10) with current DGX OS, Docker with NVIDIA runtime, user in `docker` group
- ~90 GiB free disk for the checkpoint (host HF cache / `~/.cache/halcerion`)
- ~11 GiB for the image (pull) or an active build of several minutes
- Nothing else holding the GPU at launch (one-model-at-a-time; check `nvidia-smi`)

## Credits

benthecarman (quant + the only existing GB10 measurements), Xiaomi MiMo team
(model + DFlash, MIT), turboderp (exllamav3/EXL3), theroyallab (TabbyAPI),
vcruz305 (aarch64 build fixes), MiaAI-Lab (single-Spark kit pattern),
ashhart (TensorFold — the other engine lane we trial'd for Flash-Next;
supported-arch check pending for MiMo). Full notes in `LICENSE-NOTES`.

## Status — FLIGHT 7 LIVE (2026-09-30 ~21:25 CDT)

Scaffolded 2026-09-29; flights 1-4 built/debugged the image; flight 5
parsed the 85 GiB main model clean and crashed at the drafter after 525s of cold load
(dangling symlink staging — root-caused; the download completeness gate + direct
read-only drafter mount are direct descendants of that failure);
flight 6 completed the cold load (495 s, 113 GiB peak) and flight 7 completed
verification: smoke GREEN twice (on-Spark `start.sh` smoke + off-box witness from a
second LAN host — keyless models 401, keyed 200, exact `HALCERION-KIT-OK` reply), Stage D
kill criteria ALL PASS, all 15 fix classes +15b flight-verified in the final
pre-publish revision.
Serving :8888 with DFlash + vision at 262k ctx; banner verified live 10/1.

Still open before announcement:
`DRAFT_MODE=raw` and `DRAFT_MODE=mtp` bench rows, Atlas push, HF dataset-card comment
on the pack, GHCR image push from the Spark.
