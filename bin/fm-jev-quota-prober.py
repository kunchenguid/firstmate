#!/usr/bin/env python3
"""
fm-jev-quota-prober.py - Jev System One Pre-Flight Quota & Token Health Prober.

quota-axi is the only verdict source. The prober maps a harness and model to
its quota-axi provider, reads that provider's row, and applies the same
applicable-scope rule as bin/fm-quota-choose.sh: any applicable runway
`exhausted_now` or known effective percent remaining of 0 is exhausted, a known
percent above 0 is healthy. When quota-axi marks the reading stale and reports
no known scope, the window percentRemaining quota-axi still reports (its last
reading) decides, and the verdict names it stale.

Verdicts and exit codes (single-harness mode prints `<verdict> <harness> <model>`):
  healthy    0  quota-axi reports runway for the lane.
  unmetered  0  no quota-axi provider measures this harness/model; launch as requested.
  diverted   0  --auto-divert only: the lane is exhausted and the printed lane is a
                divert target quota-axi reports fresh and healthy.
  unknown    0  quota-axi could not give a verdict (missing, failed, no row, not
                set up, no measured window); a named stderr diagnostic says so and
                the launch proceeds as requested. Never diverts.
  exhausted  1  quota-axi reports the lane exhausted and no divert was chosen.

select_divert() only picks a divert target quota-axi reports fresh and healthy;
bin/fm-spawn.sh re-probes the printed target and refuses it unless healthy.

Test seam: with FM_TEST_SEAM=1, FM_TEST_QUOTA_SNAPSHOT=<quota-axi --json file>
answers every provider from that file instead of running quota-axi. A provider
missing from the file is unknown, exactly as a missing row is.

Usage:
  bin/fm-jev-quota-prober.py --harness <harness> [--model <model>] [--auto-divert] [--json]
  bin/fm-jev-quota-prober.py --check-all [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HEALTHY, EXHAUSTED, UNKNOWN, UNMETERED, DIVERTED = "healthy", "exhausted", "unknown", "unmetered", "diverted"
EXIT_CODES = {HEALTHY: 0, UNMETERED: 0, DIVERTED: 0, UNKNOWN: 0, EXHAUSTED: 1}

# Captain 2026-09-21: Grok is firstmate-only. Never divert crews/no-mistakes to Grok.
# Ordered divert candidates. bin/fm-spawn.sh rebuilds launch resolution only for pi.
DIVERT_LANES = (("pi", "opencode-go/glm-5.3-flash"),)

# Harnesses whose quota-axi provider is the harness itself.
HARNESS_PROVIDERS = {"claude", "codex", "grok", "kimi", "cursor", "agy", "devin"}
# Multi-provider harnesses select the provider by the model's "<prefix>/" segment.
PREFIX_HARNESSES = {"pi", "pi-signed", "omp", "opencode"}
PREFIX_PROVIDERS = {
    "opencode-go": "opencode-go",
    "zai": "zai",
    "zai-general": "zai",
    "codex-native": "codex",
    "openai-codex": "codex",
    "claude-bridge": "claude",
    "kimi-code": "kimi",
}


def provider_for(harness: str, model: str) -> str | None:
    if harness in HARNESS_PROVIDERS:
        return harness
    if harness in PREFIX_HARNESSES and "/" in model:
        return PREFIX_PROVIDERS.get(model.split("/", 1)[0])
    return None


def account_lane(harness: str, model: str) -> str:
    """Same binding as quota_lane in bin/fm-quota-axi-lib.sh."""
    if harness == "codex":
        return "codex-home"
    if harness in ("pi", "pi-signed") and "/" in model:
        prefix = model.split("/", 1)[0]
        return "codex-home" if prefix == "codex-native" else prefix
    return ""


def read_quota(provider: str) -> tuple[dict | None, str]:
    """Return (quota-axi snapshot, '') or (None, named reason)."""
    snapshot = os.environ.get("FM_TEST_QUOTA_SNAPSHOT", "")
    if os.environ.get("FM_TEST_SEAM") == "1" and snapshot:
        try:
            return json.loads(Path(snapshot).read_text(encoding="utf-8")), ""
        except (OSError, ValueError) as exc:
            return None, f"test quota snapshot unreadable: {exc}"
    quota_axi = shutil.which("quota-axi")
    if not quota_axi:
        return None, "quota-axi is not installed"
    try:
        res = subprocess.run(
            [quota_axi, "--provider", provider, "--json", "--max-age", "60s"],
            capture_output=True, text=True, timeout=20, check=False,
        )
    except subprocess.TimeoutExpired:
        return None, "quota-axi timed out"
    if res.returncode != 0:
        return None, f"quota-axi exited {res.returncode}: {(res.stderr or res.stdout).strip()[:200]}"
    try:
        return json.loads(res.stdout), ""
    except ValueError:
        return None, "quota-axi returned invalid JSON"


def quota_row(snapshot: dict, provider: str, lane: str) -> dict | None:
    rows = [p for p in snapshot.get("providers", []) if p.get("provider") == provider]
    if snapshot.get("schemaVersion") == 6:
        return next((r for r in rows if r.get("accountKey") == lane), None) or \
            next((r for r in rows if r.get("accountKey") == "default"), None)
    return rows[0] if rows else None


def verdict_from_row(row: dict, model: str) -> dict:
    """quota-axi's verdict for one row: {status, percent, fresh, detail}."""
    token = model.split("/", 1)[1] if "/" in model else model
    scopes = [
        s for s in row.get("quotaSemantics", {}).get("effectiveAvailability", [])
        if s.get("scope") in ("all_models", "all_products")
        or (token and s.get("scope", "").split(":", 1)[-1] == token
            and s.get("scope", "").startswith(("model:", "product:")))
    ]
    stale = bool(row.get("state", {}).get("stale"))
    if row.get("notSetUp"):
        return {"status": UNKNOWN, "percent": None, "fresh": False,
                "detail": f"not set up ({row.get('state', {}).get('error', 'no credential')})"}
    for s in scopes:
        if s.get("runway", {}).get("status") == "exhausted_now":
            return {"status": EXHAUSTED, "percent": s.get("effectivePercentRemaining", 0), "fresh": not stale,
                    "detail": f"{s['scope']} runway exhausted_now"}
    known = [s for s in scopes if s.get("status") == "known" and isinstance(s.get("effectivePercentRemaining"), (int, float))]
    if known:
        worst = min(known, key=lambda s: s["effectivePercentRemaining"])
        pct = worst["effectivePercentRemaining"]
        return {"status": HEALTHY if pct > 0 else EXHAUSTED, "percent": pct, "fresh": not stale,
                "detail": f"{worst['scope']} {pct}% remaining"}
    windows = [w for w in row.get("windows", []) if isinstance(w.get("percentRemaining"), (int, float))]
    if stale and windows:
        worst = min(windows, key=lambda w: w["percentRemaining"])
        pct = worst["percentRemaining"]
        return {"status": HEALTHY if pct > 0 else EXHAUSTED, "percent": pct, "fresh": False,
                "detail": f"{worst.get('id', 'window')} {pct}% remaining (stale reading)"}
    return {"status": UNKNOWN, "percent": None, "fresh": False, "detail": "no measured quota scope or window"}


def probe(harness: str, model: str) -> dict:
    harness, model = harness.lower().strip(), (model or "").strip()
    result = {"harness": harness, "model": model, "source": "quota-axi"}
    provider = provider_for(harness, model)
    if provider is None:
        return {**result, "status": UNMETERED, "percent": None, "fresh": False, "provider": None,
                "reason": f"no quota-axi provider measures {harness}{':' + model if model else ''}"}
    snapshot, err = read_quota(provider)
    row = quota_row(snapshot, provider, account_lane(harness, model)) if snapshot else None
    if snapshot is None:
        verdict = {"status": UNKNOWN, "percent": None, "fresh": False, "detail": err}
    elif row is None:
        verdict = {"status": UNKNOWN, "percent": None, "fresh": False, "detail": f"quota-axi has no {provider} row"}
    else:
        verdict = verdict_from_row(row, model)
    result.update(status=verdict["status"], percent=verdict["percent"], fresh=verdict["fresh"],
                  provider=provider, reason=f"quota-axi {provider}: {verdict['detail']}")
    return result


def select_divert(original: tuple[str, str]) -> tuple[str, str] | None:
    for lane in DIVERT_LANES:
        if lane == original:
            continue
        res = probe(*lane)
        if res["status"] == HEALTHY and res["fresh"]:
            return lane
    return None


def report(res: dict) -> None:
    if res["status"] == UNKNOWN:
        print(f"jev-quota-prober: quota-axi verdict unavailable for {res['harness']}:{res['model'] or '-'}: "
              f"{res['reason']}; launching as requested", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Jev Pre-Flight Quota & Token Health Prober (quota-axi verdicts)")
    parser.add_argument("--harness", help="Harness to probe (e.g. pi, codex, cursor)")
    parser.add_argument("--model", default="", help="Model to probe (e.g. opencode-go/glm-5.3-flash)")
    parser.add_argument("--auto-divert", action="store_true", help="On an exhausted lane, print a quota-axi-healthy divert lane")
    parser.add_argument("--check-all", action="store_true", help="Probe all standard fleet harnesses")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args()

    if args.check_all:
        results = [probe(h, m) for h, m in (
            ("cursor", "gpt-5.6-luna-high"), ("codex", "gpt-5.6-luna"),
            ("pi", "opencode-go/glm-5.3-flash"), ("pi", "zai-general/glm-5.3-flash"), ("agy", "gemini-3.8-flash-high"),
        )]
        for r in results:
            report(r)
        if args.json:
            print(json.dumps(results, indent=2))
        else:
            print("Fleet Pre-Flight Harness Runway (source: quota-axi):")
            for r in results:
                print(f"  {r['status']:<9} {r['harness']} ({r['model']}): {r['reason']}")
        return 0

    if not args.harness:
        parser.print_help()
        return 2

    res = probe(args.harness, args.model)
    report(res)
    if args.json:
        print(json.dumps(res, indent=2))
        return EXIT_CODES[res["status"]]

    if res["status"] == EXHAUSTED and args.auto_divert:
        lane = select_divert((res["harness"], res["model"]))
        if lane:
            print(f"jev-quota-prober: {res['harness']}:{res['model'] or '-'} exhausted ({res['reason']}); "
                  f"diverting to {lane[0]}:{lane[1]}", file=sys.stderr)
            print(f"{DIVERTED} {lane[0]} {lane[1]}")
            return 0
        print(f"jev-quota-prober: {res['harness']}:{res['model'] or '-'} exhausted ({res['reason']}) "
              "and no divert lane is healthy in quota-axi", file=sys.stderr)

    print(f"{res['status']} {res['harness']} {res['model']}".rstrip())
    return EXIT_CODES[res["status"]]


if __name__ == "__main__":
    sys.exit(main())
