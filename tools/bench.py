#!/usr/bin/env python3
"""bench.py — Halcerion kit measurement suite (replicates + extends the pack author's protocol).

Protocol (defaults) per lane: greedy (temperature 0), 512 generated tokens,
median of 3 runs, batch 1. Lanes mirror benthecarman's Speed table so our
numbers are directly comparable, then agent-realism lanes extend it.

Usage:
  python3 tools/bench.py --base-url "http://127.0.0.1:${PORT}" --api-key "$API_KEY"
                         # (--base-url is required, no drift-prone default;
                         #  source the kit .env so PORT/API_KEY match the live server)
                         [--model NAME]
                         [--lanes coding,prose,reasoning,code_edit,swe,toolcall,repetition]
                         [--runs 3] [--max-tokens 512] [--out results.json]
                         [--thinking]   # keep reasoning on (behavioral lanes); default OFF

Measured fields per lane: decode tok/s (completion tokens / wall), TTFT,
acceptance-proxy ratio (if draft path changes output length it shows here —
drafter never changes text, so identical prompts across runs = sanity gate).
"""
import argparse, json, statistics, time, urllib.request, sys

PROMPTS = {
    "coding":     "Write a performant Python implementation of an LRU cache with O(1) get/set and thread safety. Include docstring and tests inline.",
    "prose":      "Write a short essay on why unified memory architectures change consumer AI hardware economics. Be concrete, avoid filler.",
    "reasoning":  "A train leaves at 3:47 PM traveling 62 mph; a second leaves 41 minutes later at 79 mph. At what clock time does it pass the first? Show the reasoning then give the answer as HH:MM PM.",
    "code_edit":  "Here is a function:\n\n```python\ndef sum_list(items):\n    total = 0\n    for i in range(len(items)):\n        total += items[i]\n    return total\n```\n\nRewrite it pythonically, add type hints, and explain each change briefly.",
    "swe":        "You are given a failing test:\n(test) AssertionError: expected '2026-09-30' >= cutoff, got '2026-09-29'\n\nThe cutoff is computed as `date.today() - timedelta(days=1)` but the API stores dates in UTC while tests run in US/Central. Diagnose and propose the minimal fix, then show the corrected code.",
    "toolcall":   "Call the tool `get_weather` with city='Tulsa' and unit='celsius', then stop.",  # harness supplies the tool schema in real use
    "repetition": "List the files you would create for a blog platform in exactly 5 tool calls, then STOP. Do not repeat any call.",
}

def call(base_url, model, api_key, prompt, max_tokens, timeout=1200, thinking=False):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        # Fix #13 part 1: flight-7 verified — with thinking on (template default),
        # a 512-token budget can be fully consumed by reasoning and `content`
        # comes back null (finish_reason: length); that crashed the reporter and
        # it also muddies decode measurement. Speed lanes measure decode, so the
        # default bench payload disables thinking. Use --thinking for the
        # behavioral probes (toolcall/repetition) where reasoning realism matters.
        **({} if thinking else {"chat_template_kwargs": {"enable_thinking": False}}),
    }).encode()
    req = urllib.request.Request(base_url.rstrip("/") + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json",
                                          **({"Authorization": f"Bearer {api_key}"} if api_key else {})})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.loads(r.read())
    wall = time.time() - t0
    usage = data.get("usage", {})
    message = data["choices"][0].get("message") or {}
    content = message.get("content") or ""
    reasoning = message.get("reasoning_content") or ""
    details = usage.get("completion_tokens_details") or {}
    # Fix #14: TabbyAPI reports per-request timings inside `usage` (verified
    # live, flight 7: prompt_time, prompt_tokens_per_sec, completion_time,
    # completion_tokens_per_sec) — NOT a top-level `timings` block; the #13
    # fields read the wrong dict and recorded nulls. Server numbers now come
    # from usage, and tool-call presence is captured for the toolcall lane.
    tool_calls = message.get("tool_calls") or []
    return {
        "wall_s": round(wall, 2),
        "completion_tokens": usage.get("completion_tokens"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "decode_tok_s": round((usage.get("completion_tokens") or 0) / wall, 2),
        # server-side timing (TabbyAPI usage block) — cross-checks our wall math
        "server_completion_tok_s": usage.get("completion_tokens_per_sec"),
        "server_completion_time_s": usage.get("completion_time"),
        "server_ttft_s": usage.get("prompt_time"),
        "server_prefill_tok_s": usage.get("prompt_tokens_per_sec"),
        # DFlash drafter acceptance proxy (when the endpoint reports it)
        "draft_accepted": details.get("accepted_prediction_tokens"),
        "draft_rejected": details.get("rejected_prediction_tokens"),
        "finish_reason": data["choices"][0].get("finish_reason"),
        "content_chars": len(content),
        "reasoning_chars": len(reasoning),
        "n_tool_calls": len(tool_calls),
        "tool_call_names": [tc.get("function", {}).get("name") for tc in tool_calls],
    }

def discover_model(base_url, api_key=""):
    """Query /v1/models; TabbyAPI reports its config model id (not a brand name).

    Fix #12: the request must carry the API key — with auth enabled (api_tokens.yml
    seeded by start.sh), keyless discovery 401s before any lane can run. Same
    breakable-client class as #8/#10: one code path authed, a sibling didn't.
    """
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    req = urllib.request.Request(base_url.rstrip("/") + "/v1/models", headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.loads(r.read())
    return data["data"][0]["id"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", default=None)  # None = discover from /v1/models
    ap.add_argument("--api-key", default="")
    ap.add_argument("--lanes", default="coding,prose,reasoning,code_edit,swe,toolcall,repetition")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--thinking", action="store_true",
                    help="leave the model's thinking mode on (default: disabled for clean decode measurement)")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    if args.model is None:
        args.model = discover_model(args.base_url, args.api_key)
        print(f"discovered model id from /v1/models: {args.model}")

    results, failures = {}, 0
    for lane in args.lanes.split(","):
        if lane not in PROMPTS:
            print(f"skip unknown lane {lane}", file=sys.stderr); continue
        runs = []
        for i in range(args.runs):
            try:
                runs.append(call(args.base_url, args.model, args.api_key, PROMPTS[lane],
                                 args.max_tokens, thinking=args.thinking))
            except Exception as e:
                failures += 1
                print(f"[{lane}] run {i+1} FAILED: {e}", file=sys.stderr)
        if runs:
            results[lane] = {
                "runs": runs,
                "median_decode_tok_s": statistics.median(r["decode_tok_s"] for r in runs),
                "median_wall_s": statistics.median(r["wall_s"] for r in runs),
                "std_content_chars": round(statistics.pstdev([r["content_chars"] for r in runs]), 1),
            }
            print(f"[{lane}] median {results[lane]['median_decode_tok_s']} tok/s "
                  f"({results[lane]['median_wall_s']}s wall, {args.runs} runs)")
        # Fix #13 part 2: a lane with ALL runs failed used to KeyError the
        # reporter after the loop — summarize and fail loud instead.
        else:
            print(f"[{lane}] ALL {args.runs} runs failed", file=sys.stderr)

    if failures == len(args.lanes.split(",")) * args.runs:
        sys.exit("bench.py: every run failed - nothing measured (server up? key right?)")

    results["_meta"] = {"failures": failures, "max_tokens": args.max_tokens, "runs_per_lane": args.runs,
                        "thinking": bool(args.thinking),
                        "protocol": "greedy, batch1, median-of-N, mirrors benthecarman Speed table"}
    out = json.dumps(results, indent=2)
    print(out)
    if args.out:
        open(args.out, "w").write(out)

if __name__ == "__main__":
    main()