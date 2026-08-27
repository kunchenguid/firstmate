#!/usr/bin/env bash
# fm-usage-by-model.sh
# Aggregate token usage across local harness sources (opencode, claude-code).
# Pi: no local per-turn token artifact found in ~/.pi (investigated 2026-08-27); omitted without silent drop.
# Output: preserves legacy JSON (models[]/total/query_time); adds --csv, --today/--since, multi-source grouping.
# note field: "list-price estimate" for Claude Code (corporate contract, not list); blank or "billed" for others when authoritative.
# Rates: reuse data/usage-rates.json if present (relative to repo root), else built-in Anthropic/OpenAI/xAI.
# Flags: --json (default), --csv, --today, --since YYYY-MM-DD, --help.
# Read-only on all sources; absent source -> zero contrib, never fail.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RATES_FILE="${REPO_ROOT}/data/usage-rates.json"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--json|--csv] [--today|--since YYYY-MM-DD] [--help]

Aggregates per-message token usage from local harness stores.
Sources: opencode (SQLite ~/.local/share/opencode/opencode.db), claude-code (JSONL ~/.claude/projects/**/*.jsonl).
Pi source: none (no local artifact).

Output groups by (date, source, provider, model) with turns, tokens, est_cost_usd, note.
--json: legacy shape {models:[], total:{}, query_time} for backward compat (jq '.total' etc).
--csv: date,source,provider,model,turns,input_tokens,... ,est_cost_usd,note (matches prior ad-hoc CSV).
--today: equivalent to --since $(date +%Y-%m-%d)
--since: filter to date >= YYYY-MM-DD (UTC day bucket from timestamps).
Absent sources report zero; never error.
EOF
}

MODE=json
SINCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) MODE=json; shift ;;
    --csv) MODE=csv; shift ;;
    --today) SINCE="$(date +%Y-%m-%d)"; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

python3 - "$MODE" "$SINCE" "$RATES_FILE" <<'PYEOF'
import json, sqlite3, os, sys, glob, datetime, re
from collections import defaultdict
from pathlib import Path

mode, since, rates_file = sys.argv[1], sys.argv[2], sys.argv[3]
since_date = since or ""

# rates
rates = {
  "anthropic": {
    "claude-3-5-sonnet": (3,15,0,0),
    "claude-opus-4": (15,75,0,0),
    "claude-sonnet-4": (3,15,0,0),
    "claude-sonnet-5": (3,15,0,0),
    "claude-opus-4-8": (15,75,0,0),
  },
  "openai": {"gpt-4o": (2.5,10,0,0)},
  "xai": {"grok-4": (5,15,0,0)},
}
if os.path.exists(rates_file):
  try:
    with open(rates_file) as f:
      file_rates = json.load(f)
      for prov, models in file_rates.items():
        if prov not in rates: rates[prov] = {}
        rates[prov].update(models)
  except Exception:
    pass

def match_rate(provider, model):
  p = provider.lower() if provider else ""
  m = model.lower() if model else ""
  if p in rates:
    for key, val in rates[p].items():
      if key in m or m in key:
        return val
  # generous substring
  for prov, md in rates.items():
    for key, val in md.items():
      if key in m:
        return val
  return (0,0,0,0) # unknown -> 0 cost

def day_bucket(ts):
  if isinstance(ts, (int, float)):
    dt = datetime.datetime.fromtimestamp(ts/1000, tz=datetime.timezone.utc)
  else:
    dt = datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
  return dt.date().isoformat()

agg = defaultdict(lambda: {"turns":0, "input":0, "output":0, "cache_read":0, "cache_write":0, "note":""})

# opencode source
oc_db = os.path.expanduser("~/.local/share/opencode/opencode.db")
if os.path.exists(oc_db):
  try:
    con = sqlite3.connect(oc_db)
    cur = con.cursor()
    for row in cur.execute("SELECT time_created, data FROM message WHERE data IS NOT NULL"):
      ts, data = row
      try:
        d = json.loads(data)
        prov = d.get("providerID") or "unknown"
        mdl = d.get("modelID") or "unknown"
        toks = d.get("tokens") or {}
        day = day_bucket(ts)
        if since_date and day < since_date: continue
        key = (day, "opencode", prov, mdl)
        agg[key]["turns"] += 1
        agg[key]["input"] += toks.get("input",0) or 0
        agg[key]["output"] += toks.get("output",0) or 0
        agg[key]["cache_read"] += toks.get("cache.read",0) or 0
        agg[key]["cache_write"] += toks.get("cache.write",0) or 0
        agg[key]["note"] = ""
      except Exception:
        continue
    con.close()
  except Exception:
    pass

# claude-code source
cc_glob = os.path.expanduser("~/.claude/projects/**/*.jsonl")
for jf in glob.glob(cc_glob, recursive=True):
  try:
    with open(jf) as f:
      for line in f:
        if not line.strip(): continue
        try:
          obj = json.loads(line)
          msg = obj.get("message") or {}
          if msg.get("role") != "assistant": continue
          model = msg.get("model") or ""
          if not model or model == "<synthetic>": continue
          usage = msg.get("usage") or {}
          ts = obj.get("timestamp") or ""
          day = day_bucket(ts)
          if since_date and day < since_date: continue
          prov = "anthropic"
          key = (day, "claude-code", prov, model)
          agg[key]["turns"] += 1
          agg[key]["input"] += usage.get("input_tokens",0) or 0
          agg[key]["output"] += usage.get("output_tokens",0) or 0
          agg[key]["cache_read"] += usage.get("cache_read_input_tokens",0) or 0
          agg[key]["cache_write"] += usage.get("cache_creation_input_tokens",0) or 0
          agg[key]["note"] = "list-price estimate"
        except Exception:
          continue
  except Exception:
    pass

# build rows
rows = []
for (day, src, prov, mdl), v in sorted(agg.items()):
  inp, out, cr, cw = v["input"], v["output"], v["cache_read"], v["cache_write"]
  ir, or_, _, _ = match_rate(prov, mdl)
  cost = (inp * ir + out * or_) / 1_000_000.0
  rows.append({
    "date": day, "source": src, "provider": prov, "model": mdl,
    "turns": v["turns"], "input_tokens": inp, "output_tokens": out,
    "cache_read_tokens": cr, "cache_write_tokens": cw,
    "est_cost_usd": round(cost, 4), "note": v["note"]
  })

if mode == "csv":
  print("date,source,provider,model,turns,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,est_cost_usd,note")
  for r in rows:
    print(",".join(str(r[k]) for k in ["date","source","provider","model","turns","input_tokens","output_tokens","cache_read_tokens","cache_write_tokens","est_cost_usd","note"]))
else:
  # legacy json shape + extra day/source breakdown
  models = {}
  total = {"turns":0,"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_write_tokens":0,"est_cost_usd":0}
  for r in rows:
    mk = f"{r['provider']}:{r['model']}"
    if mk not in models:
      models[mk] = {"provider":r['provider'],"model":r['model'],"turns":0,"input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_write_tokens":0,"est_cost_usd":0,"note":r['note']}
    for k in ["turns","input_tokens","output_tokens","cache_read_tokens","cache_write_tokens"]:
      models[mk][k] += r[k]
    models[mk]["est_cost_usd"] = round(models[mk]["est_cost_usd"] + r["est_cost_usd"],4)
    for k in ["turns","input_tokens","output_tokens","cache_read_tokens","cache_write_tokens"]:
      total[k] += r[k]
    total["est_cost_usd"] = round(total["est_cost_usd"] + r["est_cost_usd"],4)
  print(json.dumps({"models": list(models.values()), "total": total, "query_time": datetime.datetime.now(datetime.timezone.utc).isoformat(), "sources": ["opencode","claude-code"], "pi_note": "no local per-turn token log found"}, indent=2))
PYEOF
