#!/usr/bin/env python3
"""
fm-jev-quota-prober.py - Jev System One Pre-Flight Quota & Token Health Prober.

Performs sub-second runway and credential probes before worker launch to prevent
429 quota exhaustion and revoked-token stalls. Automatically diverts doomed
worker spawns to viable high-runway lanes (e.g. Cursor Grok 4.6 High).

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

DEFAULT_SAFE_HARNESS = "cursor"
DEFAULT_SAFE_MODEL = "cursor-grok-4.6-high"


def query_quota_axi(providers: list[str] | None = None) -> dict:
    """Fetch structured quota evidence from quota-axi in sub-second time."""
    quota_axi_bin = shutil.which("quota-axi") or "/home/jon/.npm-global/bin/quota-axi"
    if not os.path.exists(quota_axi_bin):
        return {}

    cmd = [quota_axi_bin, "--json"]
    if providers:
        cmd.extend(["--provider", ",".join(providers)])

    try:
        res = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if res.returncode == 0:
            return json.loads(res.stdout)
    except Exception:
        pass
    return {}


def is_zai_bundle_dry() -> bool:
    """Check if zai-general API bundle has been confirmed dry by fleet spend facts."""
    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    # 1. Check direct marker if present
    marker = fm_root / "state" / ".zai-bundle-dry"
    if marker.exists():
        return True

    # 2. Check recent branch outcomes for confirmed spend fact
    outcomes_f = fm_root / "state" / "branch-outcomes.jsonl"
    if outcomes_f.exists():
        try:
            # Read last 50 lines
            lines = outcomes_f.read_text(encoding="utf-8", errors="replace").splitlines()[-50:]
            for line in reversed(lines):
                if "zai-general" in line and ("dry" in line.lower() or "insufficient balance" in line.lower()):
                    return True
        except Exception:
            pass
    return True  # Default to dry given confirmed 2026-09-21 spend fact


def probe_harness(harness: str, model: str | None = None) -> dict:
    """
    Probe a specific harness and model combination.
    Returns health: 'healthy', 'exhausted', 'revoked', 'unknown'.
    """
    harness = harness.lower().strip()
    model = (model or "").lower().strip()

    quota_data = query_quota_axi([harness] if harness in ["claude", "codex", "cursor", "zai"] else None)
    providers = {p.get("provider"): p for p in quota_data.get("providers", [])}

    # 1. Codex Probe
    if harness == "codex":
        codex_info = providers.get("codex", {})
        state = codex_info.get("state", {})
        if state.get("error") or state.get("stale"):
            return {
                "harness": harness,
                "model": model,
                "status": "revoked_or_unavailable",
                "healthy": False,
                "reason": state.get("error") or "Codex credentials unavailable or revoked",
                "divert_harness": DEFAULT_SAFE_HARNESS,
                "divert_model": DEFAULT_SAFE_MODEL,
            }
        credits = codex_info.get("credits", {}).get("remaining", 1)
        if credits <= 0:
            return {
                "harness": harness,
                "model": model,
                "status": "exhausted",
                "healthy": False,
                "reason": "Codex balance zero / exhausted",
                "divert_harness": DEFAULT_SAFE_HARNESS,
                "divert_model": DEFAULT_SAFE_MODEL,
            }

    # 2. Pi / Zai Probe
    elif harness == "pi":
        if "zai-general" in model or "glm" in model:
            if is_zai_bundle_dry():
                return {
                    "harness": harness,
                    "model": model,
                    "status": "exhausted",
                    "healthy": False,
                    "reason": "zai-general bundle is DRY (spend fact: insufficient balance)",
                    "divert_harness": DEFAULT_SAFE_HARNESS,
                    "divert_model": DEFAULT_SAFE_MODEL,
                }

    # 3. Cursor Probe
    elif harness == "cursor":
        cursor_info = providers.get("cursor", {})
        scopes = {
            s.get("scope"): s
            for s in cursor_info.get("quotaSemantics", {}).get("effectiveAvailability", [])
        }

        # If requesting Grok specifically
        if "grok" in model:
            grok_scope = scopes.get("grok_bot", {})
            rem = grok_scope.get("effectivePercentRemaining", 0)
            if rem > 10:
                return {
                    "harness": harness,
                    "model": model,
                    "status": "healthy",
                    "healthy": True,
                    "reason": f"Grok runway confirmed ({rem}% remaining)",
                    "divert_harness": harness,
                    "divert_model": model,
                }

        # For general Cursor models, check all_models
        all_models = scopes.get("all_models", {})
        if all_models.get("runway", {}).get("status") == "exhausted_now" or all_models.get("effectivePercentRemaining", 1) == 0:
            return {
                "harness": harness,
                "model": model,
                "status": "exhausted",
                "healthy": False,
                "reason": "Cursor generic quota exhausted; Grok Bot pool available",
                "divert_harness": DEFAULT_SAFE_HARNESS,
                "divert_model": DEFAULT_SAFE_MODEL,
            }

    return {
        "harness": harness,
        "model": model,
        "status": "healthy",
        "healthy": True,
        "reason": "No quota blockers detected",
        "divert_harness": harness,
        "divert_model": model,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Jev Pre-Flight Quota & Token Health Prober")
    parser.add_argument("--harness", help="Harness to probe (e.g. pi, codex, cursor)")
    parser.add_argument("--model", help="Model to probe (e.g. zai-general/glm-5.3-flash, cursor-grok-4.6-high)")
    parser.add_argument("--auto-divert", action="store_true", help="Emit diverted harness and model if target is unhealthy")
    parser.add_argument("--check-all", action="store_true", help="Probe all standard fleet harnesses")
    parser.add_argument("--json", action="store_true", help="Output JSON")

    args = parser.parse_args()

    if args.check_all:
        results = [
            probe_harness("cursor", "cursor-grok-4.6-high"),
            probe_harness("cursor", "cursor-small"),
            probe_harness("codex", "gpt-5.6-luna"),
            probe_harness("pi", "zai-general/glm-5.3-flash"),
        ]
        if args.json:
            print(json.dumps(results, indent=2))
        else:
            print("Fleet Pre-Flight Harness Runway:")
            for r in results:
                icon = "✓" if r["healthy"] else "✗"
                div = f" -> divert to {r['divert_harness']}:{r['divert_model']}" if not r["healthy"] else ""
                print(f"  {icon} {r['harness']} ({r['model']}): {r['status']} ({r['reason']}){div}")
        return 0

    if not args.harness:
        parser.print_help()
        return 2

    res = probe_harness(args.harness, args.model)

    if args.json:
        print(json.dumps(res, indent=2))
        return 0 if res["healthy"] else 1

    if args.auto_divert:
        print(f"harness={res['divert_harness']} model={res['divert_model']} healthy={1 if res['healthy'] else 0}")
        return 0

    if res["healthy"]:
        print(f"ok: {res['harness']} ({res['model']}) is healthy: {res['reason']}")
        return 0
    else:
        print(f"blocked: {res['harness']} ({res['model']}) unhealthy: {res['reason']} (recommended: {res['divert_harness']} {res['divert_model']})", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
