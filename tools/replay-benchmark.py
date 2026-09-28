#!/usr/bin/env python3
"""Replay benchmark: would another router have picked the same model and effort you did?

The dispatch gate logs every subagent launch to
~/.claude/dispatch-logs/agent-dispatch.jsonl (model, effort, type, description).
This tool replays those past launches through any router and reports how often
the router agrees with your actual picks, overall and by the router's confidence.

It measures agreement with your history, not quality: a router that disagrees
may be right. Use it to decide whether a router is worth wiring in before
trusting it with live dispatches.

Usage:
  # 1. Export the rows (descriptions are scrubbed of emails, phones, addresses, names)
  tools/replay-benchmark.py export > rows.jsonl

  # 2. Score a router. The router command reads rows.jsonl lines on stdin
  #    ({"id","desc"}) and prints one JSON line per row:
  #    {"id": ..., "tier": "haiku|sonnet|opus|...", "effort": "low|medium|high|xhigh|max", "confidence": 0.0-1.0}
  #    tier, effort, and confidence are each optional.
  tools/replay-benchmark.py score --router "python3 my_router.py"

  # Or score a predictions file you produced some other way (e.g. a batch LLM classifier)
  tools/replay-benchmark.py score --predictions preds.jsonl

  # Built-in keyword baseline, to have something to beat
  tools/replay-benchmark.py score --baseline

Options: --log PATH (default $DISPATCH_LOG_DIR/agent-dispatch.jsonl), --limit N,
--include-workers (by default only parent-session dispatches count), --no-scrub.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter

DEFAULT_LOG = os.path.join(
    os.environ.get("DISPATCH_LOG_DIR", os.path.expanduser("~/.claude/dispatch-logs")),
    "agent-dispatch.jsonl",
)

# Scrub personal data out of descriptions before they leave your machine.
SCRUB = [
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "<email>"),
    (re.compile(r"\+?\d[\d\s().-]{8,}\d"), "<phone>"),
    (re.compile(r"\b\d{1,6}\s+(?:[A-Z][a-z]+\s){1,4}(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Pl|Place|Ln|Lane|Dr|Drive|Ct|Court|Way|Pkwy|Ter|Terrace)\b\.?", re.I), "<address>"),
    (re.compile(r"\b(?:apt|unit|suite|#)\s*\w+\b", re.I), "<unit>"),
    (re.compile(r"\b[A-Z][a-z]+(?:\s[A-Z][a-z]+)?'s\b"), "<name>'s"),
    (re.compile(r"\b(?:sk|pk|rk|ghp|gho|xox[abp])[-_][A-Za-z0-9_-]{10,}\b"), "<secret>"),
    (re.compile(r"\b[0-9a-f]{32,}\b", re.I), "<hex>"),
]

TIERS = ("haiku", "sonnet", "opus", "fable")
EFFORTS = ("low", "medium", "high", "xhigh", "max")


def scrub(text):
    for pat, rep in SCRUB:
        text = pat.sub(rep, text)
    return text


def norm_tier(model):
    m = (model or "").lower()
    for t in TIERS:
        if t in m:
            return t
    return m or None


def load_rows(args):
    rows = []
    try:
        fh = open(args.log, encoding="utf-8")
    except OSError as e:
        sys.exit(f"cannot read {args.log}: {e}")
    with fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("decision") not in (None, "allow"):
                continue  # denied or prompted launches have no settled pick
            if r.get("inside_worker") == "yes" and not args.include_workers:
                continue
            tier = norm_tier(r.get("model"))
            if tier in (None, "inherit"):
                continue
            effort = r.get("effort")
            desc = r.get("desc") or ""
            rows.append({
                "id": len(rows),
                "desc": desc if args.no_scrub else scrub(desc),
                "type": r.get("type"),
                "tier": tier,
                "effort": effort if effort in EFFORTS else None,
            })
    if args.limit:
        rows = rows[-args.limit:]
        for i, r in enumerate(rows):
            r["id"] = i
    return rows


def baseline(row):
    d = row["desc"].lower()
    if re.search(r"\b(find|list|count|inventory|where|scan|grep|map|locate|recon)\b", d):
        return {"id": row["id"], "tier": "haiku", "effort": "low", "confidence": 0.6}
    if re.search(r"\b(research|docs|compare|what do people|changelog)\b", d):
        return {"id": row["id"], "tier": "sonnet", "effort": "medium", "confidence": 0.6}
    if re.search(r"\b(review|audit|security|auth|payment|debug|root cause|escalat)\b", d):
        return {"id": row["id"], "tier": "opus", "effort": "xhigh", "confidence": 0.7}
    return {"id": row["id"], "tier": "opus", "effort": "medium", "confidence": 0.5}


def get_predictions(args, rows):
    if args.baseline:
        return {p["id"]: p for p in map(baseline, rows)}
    if args.predictions:
        src = open(args.predictions, encoding="utf-8").read()
    else:
        feed = "".join(json.dumps({"id": r["id"], "desc": r["desc"]}) + "\n" for r in rows)
        proc = subprocess.run(args.router, shell=True, input=feed, capture_output=True, text=True)
        if proc.returncode != 0:
            sys.exit(f"router exited {proc.returncode}: {proc.stderr[-500:]}")
        src = proc.stdout
    preds = {}
    for line in src.splitlines():
        try:
            p = json.loads(line)
            preds[int(p["id"])] = p
        except (ValueError, KeyError, TypeError):
            continue
    return preds


def pct(a, b):
    return f"{100 * a / b:.0f}% ({a}/{b})" if b else "n/a"


def score(args):
    rows = load_rows(args)
    if not rows:
        sys.exit("no scorable rows in the log yet; dispatch some subagents first")
    preds = get_predictions(args, rows)
    tier_hit = tier_n = eff_hit = eff_n = 0
    buckets = {}
    confusion = Counter()
    for r in rows:
        p = preds.get(r["id"])
        if not p:
            continue
        pt = norm_tier(p.get("tier"))
        if pt:
            tier_n += 1
            hit = pt == r["tier"]
            tier_hit += hit
            confusion[(r["tier"], pt)] += 1
            c = p.get("confidence")
            if isinstance(c, (int, float)):
                b = "high (>=0.8)" if c >= 0.8 else "mid (0.5-0.8)" if c >= 0.5 else "low (<0.5)"
                h, n = buckets.get(b, (0, 0))
                buckets[b] = (h + hit, n + 1)
        if p.get("effort") and r["effort"]:
            eff_n += 1
            eff_hit += p["effort"] == r["effort"]
    print(f"rows: {len(rows)}   predictions: {len(preds)}")
    print(f"tier agreement:   {pct(tier_hit, tier_n)}")
    print(f"effort agreement: {pct(eff_hit, eff_n)}")
    for b in ("high (>=0.8)", "mid (0.5-0.8)", "low (<0.5)"):
        if b in buckets:
            print(f"  tier agreement at confidence {b}: {pct(*buckets[b])}")
    print(f"your picks:   {dict(Counter(r['tier'] for r in rows))}")
    print("disagreements (actual -> router):")
    for (a, b), n in confusion.most_common():
        if a != b:
            print(f"  {a} -> {b}: {n}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["export", "score"])
    ap.add_argument("--log", default=DEFAULT_LOG)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--include-workers", action="store_true")
    ap.add_argument("--no-scrub", action="store_true")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--router")
    g.add_argument("--predictions")
    g.add_argument("--baseline", action="store_true")
    args = ap.parse_args()
    if args.cmd == "export":
        for r in load_rows(args):
            print(json.dumps(r))
    else:
        if not (args.router or args.predictions or args.baseline):
            ap.error("score needs --router, --predictions, or --baseline")
        score(args)


if __name__ == "__main__":
    main()
