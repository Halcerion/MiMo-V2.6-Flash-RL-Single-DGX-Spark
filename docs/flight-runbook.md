# Flight runbook — Halcerion MiMo kit (single Spark)

*This runbook documents the flight procedures used to validate the kit; every
result lands in the flight report (`results/`).*

## Stage 0 — host gates (5 min, on the Spark)
```bash
df -h ~                        # want ≥90G free for pack; the kit re-checks itself
free -g                        # MemAvailable — record it
nvidia-smi                     # note anything already resident
systemctl is-active systemd-oomd || echo "INSTALL oomd first (skill dgx-spark 9/20 rule)"
cat /etc/systemd/system/user.slice.d/oom-protection.conf | head -3   # MemoryMax=120G expected
```

## Stage A — get the kit onto the Spark + download (evening, background)
```bash
# copy the kit dir over (or git clone once published)
scp -r ~/projects/halcerion-mimo-spark-kit <spark-user>@<spark-host>:~/halcerion-kit
cd ~/halcerion-kit
cp .env.example .env
# Then edit VALUES (HOST=0.0.0.0 + real API_KEY to serve off-box). Don't append
# values after inline comments — grep/cut readers ingest the comment (flight 7).
tmux new -s mimo               # download is resumable but should survive ssh drops
./start.sh                     # first run: pull-or-build image, then downloads ~85G in tmux
```
Expect: image pull ~11G or local build (several minutes), then a long download
with steady progress. If disk gate trips, evicting other large caches is the
operator's call (know what you're evicting — anything already serving will go down).

## Stage B — first serve + smoke (~15 min after download)
```
./start.sh resumes past completed steps and launches.
Watch: config.yml correctness on first launch (typo there = container exit loop
       — Restart=unless-stopped will flap; check `docker logs halcerion-mimo-spark`)
Record: cold-load time to /health 200 (expect ~10 min class).
```
If container exits on load: check logs for the exllamav3 arch line — if it says
unsupported arch, exllamav3 in the image predates mimo2 support → verify
EXL3_REF built was ≥v1.5.2, rebuild the image (`docker build --no-cache`).

## Stage C — benchmark (~1 h)
```bash
# PORT/API_KEY come from the kit .env — the scripts always honor it
source .env
python3 tools/bench.py --base-url "http://127.0.0.1:${PORT}" --api-key "$API_KEY" \
  --out results/exl3-kit-bench-$(date +%m%d).json
```
(PORT here is whatever .env says — flights 1-6 ran 8893, current .env runs 8888.
Omitting --api-key now that auth is on = 401 on every request.)
Compare against the pack author's Speed table (README) — lanes are deliberately
his. Then the extension lanes (swe, toolcall, repetition): the repetition probe
matters because Xiaomi documented a tool-call-repetition defect on agentic
harnesses for the RL checkpoint family; if OUR 2.27bpw copy shows loops, that's
flight-report headline material (and a quant-vs-full-model question worth
filing on the pack repo).

## Stage D — quality spot-check (operator judgment, ~30 min)
Same prompts to (a) this kit, (b) Flash-Next TensorFold lane (port 8888, if
packs coexist on disk — both can't sit in memory; run sequentially, ./stop.sh
between), subjective A/B on your real agent tasks. Kill criteria from the
flight plan, updated: keep as agent-default candidate if ≥25 tok/s raw /
tool-call JSON ≥95% / no repetition loops; supersede Flash-Next only on
quality win.

## Stage E — publish (after flight verdict)
- flight report doc (standard format: what ran, failure modes, numbers, fixes)
- kit repo to github.com/Halcerion (with CREDITS + LICENSE-NOTES already drafted)
- HF org card pointing at the kit + benthecarman pack
- upstream niceties: tool-call repetition result filed on benthecarman's repo

## Failure modes we EXPECT (from our own history — check these first)
| symptom | first suspect | memory anchor |
|---|---|---|
| venv/container CUDA both dead | driver wedge → REBOOT | 9/19 Mia incident |
| container starts, torch sees no GPU | nvidia-ctk/runtime wiring | 9/19 ladder |
| download lands tiny dir | HF symlink snapshot layout | 9/19 hardlink-normalize.sh |
| start script dies silently at "Launch" | set -e + empty-glob pipefail | Mia start.sh bug |
| OOM mid-load, box freezes | one-model rule + memwatch gate | standing rule |
| config.yml typo → restart flap | Restart policy masks it | check docker logs FIRST |