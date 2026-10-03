#!/usr/bin/env python3
"""
fm-jev-quota-prober.py - Jev System One Pre-Flight Quota & Token Health Prober.

Performs sub-second runway and credential probes before worker launch to prevent
429 quota exhaustion. For a doomed lane it recommends, and with --auto-divert
emits, only a permitted lane with confirmed runway; the caller decides whether to
launch that recommendation. With --auto-divert, exit 0 prints
`harness=… model=… healthy=… status=…` (the caller must check status, since an
unknown lane can still print a diversion), exit 1 means a confirmed-doomed lane
with no diversion, and exit 3 means unmeasured runway with no diversion; a
quota-axi row error is always unknown and never diverts.

Usage:
  bin/fm-jev-quota-prober.py --harness <harness> [--model <model>] [--scan <raw launch words>] [--auto-divert] [--json]
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
DEFAULT_SAFE_MODEL = "composer-2.5"


def query_quota_axi(providers: list[str] | None = None) -> dict:
    """Fetch structured quota evidence from quota-axi in sub-second time."""
    quota_axi_bin = os.environ.get("FM_QUOTA_AXI_BIN") or shutil.which("quota-axi")
    if not quota_axi_bin or not os.access(quota_axi_bin, os.X_OK) or os.path.isdir(quota_axi_bin):
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
    """Check if the zai-general API bundle carries the explicit dry spend marker."""
    fm_root = Path(os.environ.get("FM_HOME") or Path(__file__).resolve().parent.parent)
    return (fm_root / "state" / ".zai-bundle-dry").exists()


def applicable_availability(provider: dict, model: str) -> list[dict]:
    bare_model = model.rsplit("/", 1)[-1]
    scopes = {"all_models", "all_products"}
    if bare_model:
        scopes.update({f"model:{bare_model}", f"product:{bare_model}"})
    return [
        row
        for row in provider.get("quotaSemantics", {}).get("effectiveAvailability", [])
        if row.get("scope") in scopes
    ]


def availability_exhausted(provider: dict, model: str) -> bool:
    return any(
        row.get("runway", {}).get("status") == "exhausted_now"
        or (
            row.get("status") == "known"
            and isinstance(row.get("effectivePercentRemaining"), (int, float))
            and row["effectivePercentRemaining"] <= 0
        )
        for row in applicable_availability(provider, model)
    )


def availability_confirmed(provider: dict, model: str) -> bool:
    state = provider.get("state", {})
    semantics = provider.get("quotaSemantics", {})
    rows = applicable_availability(provider, model)
    return (
        state.get("status") == "fresh"
        and state.get("stale") is False
        and not state.get("error")
        and semantics.get("status") in {"known", "partial"}
        and bool(rows)
        and all(
            row.get("status") == "known"
            and isinstance(row.get("effectivePercentRemaining"), (int, float))
            and row["effectivePercentRemaining"] > 0
            and row.get("runway", {}).get("status")
            in {"through_reset", "projected_exhaustion"}
            for row in rows
        )
    )


def select_account(quota_data: dict, harness: str, model: str) -> dict | None:
    """Bind a lane to its one quota row, mirroring quota_lane/quota_row in
    bin/fm-quota-axi-lib.sh: a sibling account of the same provider never
    stands in for (or blocks) the requested lane."""
    rows = quota_data.get("providers", [])
    lane = ""
    if harness == "codex":
        lane = "codex-home"
    elif harness in {"pi", "pi-signed"} and "/" in model:
        lane = model.split("/", 1)[0]
        lane = "codex-home" if lane == "codex-native" else lane
        # A Pi lane names an account (openai-codex-work) or a provider (codex).
        keyed = next((r for r in rows if r.get("accountKey") == lane), None)
        if keyed:
            return keyed
        lane_rows = [r for r in rows if r.get("provider") == lane]
        if quota_data.get("schemaVersion") == 6:
            # Never bind by row order: only an explicit default row stands in.
            return next((r for r in lane_rows if r.get("accountKey") == "default"), None)
        return lane_rows[0] if lane_rows else None
    provider_rows = [r for r in rows if r.get("provider") == harness]
    if quota_data.get("schemaVersion") == 6:
        for key in (lane, "default"):
            match = next((r for r in provider_rows if r.get("accountKey") == key), None)
            if match:
                return match
        return None
    return provider_rows[0] if provider_rows else None


def credits_exhausted(account: dict) -> bool:
    remaining = (account.get("credits") or {}).get("remaining")
    return isinstance(remaining, (int, float)) and remaining <= 0


def unhealthy_result(
    harness: str,
    model: str,
    status: str,
    reason: str,
    quota_data: dict,
    allow_divert: bool = True,
) -> dict:
    safe_account = select_account(quota_data, DEFAULT_SAFE_HARNESS, DEFAULT_SAFE_MODEL)
    has_safe_diversion = (
        allow_divert
        and (harness, model.rsplit("/", 1)[-1]) != (DEFAULT_SAFE_HARNESS, DEFAULT_SAFE_MODEL)
        and bool(safe_account)
        and not credits_exhausted(safe_account)
        and availability_confirmed(safe_account, DEFAULT_SAFE_MODEL)
    )
    return {
        "harness": harness,
        "model": model,
        "status": status,
        "healthy": False,
        "reason": reason,
        "divert_harness": DEFAULT_SAFE_HARNESS if has_safe_diversion else "",
        "divert_model": DEFAULT_SAFE_MODEL if has_safe_diversion else "",
    }


def probe_harness(harness: str, model: str | None = None, scan: str = "") -> dict:
    """
    Probe a specific harness and model combination.
    Returns health: 'healthy', 'exhausted', 'forbidden', 'unknown'.
    """
    harness = harness.lower().strip()
    model = (model or "").lower().strip()

    quota_data = query_quota_axi()

    if harness == "grok" or "grok" in model or "grok" in scan.lower():
        return unhealthy_result(
            harness,
            model,
            "forbidden",
            "Grok is reserved for Firstmate and cannot run crew work",
            quota_data,
        )

    # Pi GLM lanes are judged by the zai spend marker; every other lane needs
    # quota evidence from its own account row.
    if harness == "pi" and ("zai-general" in model or "glm" in model):
        if is_zai_bundle_dry():
            return unhealthy_result(
                harness,
                model,
                "exhausted",
                "zai-general bundle is DRY (spend fact: insufficient balance)",
                quota_data,
            )
    else:
        account = select_account(quota_data, harness, model)
        if not account:
            return unhealthy_result(
                harness,
                model,
                "unknown",
                "No quota evidence available; runway is unknown",
                quota_data,
            )
        provider = account.get("provider")
        state = account.get("state") or {}
        if state.get("error"):
            return unhealthy_result(
                harness,
                model,
                "unknown",
                f"{provider} quota could not be measured: {state['error']}",
                quota_data,
                allow_divert=False,
            )
        if credits_exhausted(account) or availability_exhausted(account, model):
            return unhealthy_result(
                harness,
                model,
                "exhausted",
                f"{provider} quota exhausted",
                quota_data,
            )
        if not availability_confirmed(account, model):
            return unhealthy_result(
                harness,
                model,
                "unknown",
                f"{provider} quota evidence is stale or runway is unconfirmed",
                quota_data,
            )

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
    parser.add_argument("--scan", default="", help="Raw launch words, judged only for the Grok reservation")
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
                div = f" -> divert to {r['divert_harness']}:{r['divert_model']}" if r["divert_harness"] else ""
                print(f"  {icon} {r['harness']} ({r['model']}): {r['status']} ({r['reason']}){div}")
        return 0

    if not args.harness:
        parser.print_help()
        return 2

    res = probe_harness(args.harness, args.model, args.scan)

    if args.json:
        print(json.dumps(res, indent=2))
        return 0 if res["healthy"] else 1

    if args.auto_divert:
        if res["healthy"]:
            print(f"harness={res['harness']} model={res['model']} healthy=1 status=healthy")
            return 0
        if res["divert_harness"] and res["divert_model"]:
            print(
                f"harness={res['divert_harness']} model={res['divert_model']} "
                f"healthy=0 status={res['status']}"
            )
            return 0
        print(
            f"blocked: {res['harness']} ({res['model']}) unhealthy: {res['reason']} "
            "(no permitted diversion has confirmed runway)",
            file=sys.stderr,
        )
        return 3 if res["status"] == "unknown" else 1

    if res["healthy"]:
        print(f"ok: {res['harness']} ({res['model']}) is healthy: {res['reason']}")
        return 0
    else:
        recommendation = (
            f" (recommended: {res['divert_harness']} {res['divert_model']})"
            if res["divert_harness"]
            else " (no permitted diversion has confirmed runway)"
        )
        print(f"blocked: {res['harness']} ({res['model']}) unhealthy: {res['reason']}{recommendation}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
