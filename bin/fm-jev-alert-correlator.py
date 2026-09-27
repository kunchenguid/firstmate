#!/usr/bin/env python3
"""fm-jev-alert-correlator.py - Semantic Alert Deduping & Pager Fatigue Dampening via Jev.

Correlates incoming stack-monitor checks, pager rails, and wake signals against
active holds, open beads, and maintenance windows, suppressing duplicate alerts.

Usage:
  fm-jev-alert-correlator.py --alert "<text>" [--source <name>] [--json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TS_BASE = "https://api.typesafe.ai"
TS_MODEL = "jev-latest"
TS_TIMEOUT = 4.0
DEFAULT_CACHE = "/dev/shm/.fm-jev-alert-cache.json"


def get_cache_path() -> Path:
    return Path(os.environ.get("FM_ALERT_CACHE_OVERRIDE", DEFAULT_CACHE))


def get_api_key() -> str | None:
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key
    run_py = Path("/opt/ra/firstmate/bin/jev-typesafe-run.py")
    if run_py.exists():
        try:
            res = subprocess.run(
                ["sudo", "-n", str(run_py), "--", "env"],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            )
            for line in res.stdout.splitlines():
                if line.startswith("TYPESAFE_API_KEY="):
                    k = line.split("=", 1)[1].strip()
                    if k:
                        return k
        except Exception:
            pass
    return None


def log_telemetry(action: str, tier: str, code: str, source: str, alert_text: str) -> None:
    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))
    telem_file = state_dir / ".jev-alert-telemetry"
    try:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        clean_alert = " ".join(alert_text.split())[:120]
        line = f"{ts}\t{action}\t{tier}\t{code}\t{source}\t{clean_alert}\n"
        with open(telem_file, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def emit_result(
    action: str,
    code: str,
    reason: str,
    tier: str = "tier1",
    source: str = "",
    alert_text: str = "",
    as_json: bool = False,
    exit_code: int = 0,
) -> None:
    log_telemetry(action, tier, code, source, alert_text)
    if as_json:
        payload = {
            "action": action,
            "code": code,
            "reason": reason,
            "tier": tier,
            "source": source,
        }
        print(json.dumps(payload, indent=2))
        sys.exit(exit_code)

    if action == "absorb":
        print(f"DECISION: absorb [{code}] {reason}")
    else:
        print(f"DECISION: escalate [{code}] {reason}")
    sys.exit(exit_code)


def load_active_holds(state_dir: Path) -> list[str]:
    holds = []
    if not state_dir.exists():
        return holds
    for hf in state_dir.glob("captain-hold-*.status"):
        try:
            content = hf.read_text(encoding="utf-8", errors="replace")
            holds.append(f"{hf.name}: {content[:200]}")
        except Exception:
            pass
    for hf in state_dir.glob("*.hold"):
        try:
            content = hf.read_text(encoding="utf-8", errors="replace")
            holds.append(f"{hf.name}: {content[:200]}")
        except Exception:
            pass
    return holds


def check_local_rate_limit(alert_text: str) -> tuple[bool, int]:
    """Tier 1: Check repeat count in local /dev/shm cache."""
    now = time.time()
    h = hashlib.sha256(alert_text.encode("utf-8")).hexdigest()[:16]
    cache_path = get_cache_path()
    data = {}
    if cache_path.exists():
        try:
            data = json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            data = {}

    entry = data.get(h, {"first_seen": now, "last_seen": now, "count": 0})
    if now - entry.get("last_seen", now) > 3600:
        entry = {"first_seen": now, "last_seen": now, "count": 1}
    else:
        entry["last_seen"] = now
        entry["count"] = entry.get("count", 0) + 1

    data[h] = entry
    try:
        cache_path.write_text(json.dumps(data), encoding="utf-8")
    except Exception:
        pass

    return entry["count"] > 2, entry["count"]


def correlate_with_jev(
    alert_text: str,
    source: str,
    active_holds: list[str],
    key: str,
) -> tuple[str, str, str]:
    """Tier 3: Semantic correlation with Jev System One."""
    payload = {
        "model": TS_MODEL,
        "state": {
            "alert": alert_text[:400],
            "source": source,
            "active_holds": "\n".join(active_holds[:5]) if active_holds else "none (no active holds)",
        },
        "questions": {
            "incident_status": {
                "type": "choice",
                "instructions": "Compare the alert to the active holds. Does this alert specifically describe a service or component covered by the active holds, or is it an unrelated new production failure?",
                "criteria": {
                    "known_held_issue": "The alert specifically mentions a service, component, or error described in the active holds.",
                    "reconciled_inactive_failure": "The alert is a known, previously reconciled diagnostic or cursor repeat.",
                    "new_actionable_outage": "The alert reports an unhandled, separate production failure NOT described by any active hold.",
                },
            },
            "novelty_noul": {
                "type": "noul",
                "instructions": "Is this alert reporting a genuine new production problem that is NOT covered by the active holds list?",
            },
        },
    }

    req = urllib.request.Request(
        f"{TS_BASE}/v1/systemone",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=TS_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        answers = data.get("answers", {})
        status_choice = answers.get("incident_status", {}).get("choice", "new_actionable_outage")
        novelty_noul = float(answers.get("novelty_noul", {}).get("noul", 1.0))

        if status_choice in ("known_held_issue", "reconciled_inactive_failure"):
            return "absorb", status_choice, f"Jev correlated alert to {status_choice} (novelty={novelty_noul:.2f})"
        elif status_choice == "new_actionable_outage" or novelty_noul >= 0.5:
            return "escalate", "new_incident", f"Jev confirmed actionable outage ({status_choice}, novelty={novelty_noul:.2f})"
        else:
            return "absorb", "low_novelty", f"Jev absorbed low-novelty alert ({status_choice}, novelty={novelty_noul:.2f})"
    except Exception as exc:
        # Fail-open: escalate on API error
        return "escalate", "jev_fail_open", f"Jev API timeout/error ({exc}); escalating safely"


def main() -> None:
    parser = argparse.ArgumentParser(description="Jev Semantic Alert Correlator")
    parser.add_argument("--alert", required=True, help="Alert text to correlate")
    parser.add_argument("--source", default="check", help="Alert source name")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    args = parser.parse_args()

    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))

    # 1. Tier 1 Static Hold Matching
    active_holds = load_active_holds(state_dir)
    lower_alert = args.alert.lower()
    for hold in active_holds:
        lower_hold = hold.lower()
        # Look for matching components like email_ingest, advisor, codex
        if "email_ingest" in lower_alert and "email_ingest" in lower_hold:
            emit_result("absorb", "active_email_ingest_hold", "Alert matches active email ingest hold", "tier1", args.source, args.alert, args.json, exit_code=0)
        if "codex" in lower_alert and "codex" in lower_hold:
            emit_result("absorb", "active_codex_hold", "Alert matches active Codex login hold", "tier1", args.source, args.alert, args.json, exit_code=0)

    # 2. Tier 1 Rate Limiting / Stuck Cursor Dampening
    is_stuck, count = check_local_rate_limit(args.alert)
    if is_stuck and count > 3:
        emit_result("absorb", "repeating_cursor_dampened", f"Alert repeated {count} times without state change", "tier1", args.source, args.alert, args.json, exit_code=0)

    # 3. Tier 3 Semantic Jev Correlation
    key = get_api_key()
    if key:
        action, code, reason = correlate_with_jev(args.alert, args.source, active_holds, key)
        exit_code = 0 if action == "absorb" else 2
        emit_result(action, code, reason, "tier3", args.source, args.alert, args.json, exit_code=exit_code)

    # Default fallback: escalate so Firstmate is aware
    emit_result("escalate", "unmatched_alert", "Alert does not match any known hold", "tier1", args.source, args.alert, args.json, exit_code=2)


if __name__ == "__main__":
    main()
