# MiMo-V2.6-Flash-RL on a single DGX Spark — Halcerion deployment kit

One command serves Xiaomi's MiMo-V2.6-Flash-RL (309B total / 15B active MoE, 262k ctx,
text+vision) from one GB10 DGX Spark through an OpenAI-compatible API:

```
git clone https://github.com/Halcerion/MiMo-V2.6-Flash-RL-Single-DGX-Spark.git
cd mimo-v2.6-flash-rl-single-dgx-spark
cp .env.example .env      # set API_KEY if you want it reachable beyond loopback
./start.sh
```

- Checkpoint: [`benthecarman/MiMo-V2.6-Flash-RL-exl3`](https://huggingface.co/benthecarman/MiMo-V2.6-Flash-RL-exl3)
  (EXL3 2.27 bpw, 85.28 GiB, built and benchmarked on a DGX Spark; DFlash drafter quantized to 4 bpw)
- Engine: TabbyAPI over exllamav3 v1.5.2+ (first stream with the `mimo2` architecture), compiled once
  into our container image so end users never touch a build
- Container: NVIDIA PyTorch base (`nvcr.io/nvidia/pytorch:26.07-py3`), model weights stay in the host's HF cache and bind-mount read-only
- Drafting: DFlash drafter by default, MTP heads via `DRAFT_MODE=mtp`;
  either can be switched with `./start.sh restart`
- Sampling: TabbyAPI's upstream `safe_defaults` preset (`temp 0.8 / top_k 40 / top_p 0.95 /
  min_p 0.05`)
- Safety rails built in: `MemAvailable` gate before launch,
  API-key enforcement when bound beyond loopback, no in-container tokens, one-model-at-a-time port map

## Measured Performance

Benchmarks run against the live container on a single DGX Spark:

| Test  | DGX Spark |
|---|----|
| code edit, DFlash | 34.6 tok/s |
| reasoning, DFlash | 48.7 tok/s |
| prose, DFlash | 36.1 tok/s |
| coding, DFlash | 46.55 tok/s |
| tool-call JSON (thinking on, 1024 budget) | 3/3 clean calls @ 48.0 tok/s; repetition probe: no loops |

DFlash acceptance 44-57%.

Full data in `results/flight-report-2026-09-30.md`

## Why this exists

Two gaps: 
- benthecarman's "How to run" is a manual procedure: source
build exllamav3 on aarch64, hand-split directories, hand-write config; 
- No published single-Spark recipe for MiMo-V2.6-Flash-RL existed. This kit is the
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

* benthecarman (quant + the only existing GB10 measurements)
* Xiaomi MiMo team (model + DFlash, MIT) 
* turboderp (exllamav3/EXL3)
* theroyallab (TabbyAPI),
* vcruz305 (aarch64 build fixes)
* MiaAI-Lab (single-Spark kit pattern)

Full notes in `LICENSE-NOTES`.
