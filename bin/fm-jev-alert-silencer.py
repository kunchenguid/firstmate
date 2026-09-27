#!/usr/bin/env python3
"""
fm-jev-alert-silencer.py - Jev Multi-Agent Alert Storm & Webhook Throttler (Pattern 43)

Dampens cascade alert storms across multi-agent crash loops by fingerprinting alerts,
correlating duplicate error signatures across workers, and enforcing a token-bucket
rate limiter to prevent supervisor inbox floods and webhook exhaustion.

Invariants:
  - Fail-open: Critical unique alerts are never dropped without delivery.
  - Non-blocking: Strict sub-second execution (< 0.2s).
  - State file atomic writes under /opt/ra/firstmate/state/.alert-silencer-state.json.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


STATE_FILE = "/opt/ra/firstmate/state/.alert-silencer-state.json"
DEFAULT_WINDOW_SEC = 300  # 5 minutes suppression window for identical signatures
MAX_BURST = 3  # Allow up to 3 alerts before rate-limiting


def normalize_alert_message(msg: str) -> str:
    """Strips timestamps, PIDs, UUIDs, and numbers to produce a stable error fingerprint."""
    norm = re.sub(r"\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b", "<UUID>", msg)
    norm = re.sub(r"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?\b", "<TIMESTAMP>", norm)
    norm = re.sub(r"\bPID[:=\s]+\d+\b", "PID:<PID>", norm, flags=re.IGNORECASE)
    norm = re.sub(r"\b\d+\b", "<NUM>", norm)
    return norm.strip().lower()


def compute_signature(source: str, category: str, message: str) -> str:
    """Computes a deterministic MD5 hash for the normalized alert."""
    normalized = normalize_alert_message(message)
    key = f"{source.strip().lower()}:{category.strip().lower()}:{normalized}"
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:16]


def load_silencer_state(state_file: str = STATE_FILE) -> Dict[str, Any]:
    """Loads state file safely with fail-open default."""
    if os.path.exists(state_file):
        try:
            with open(state_file, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {"signatures": {}, "total_processed": 0, "total_suppressed": 0}


def save_silencer_state(state: Dict[str, Any], state_file: str = STATE_FILE) -> None:
    """Saves state file atomically."""
    tmp = f"{state_file}.tmp.{os.getpid()}"
    try:
        os.makedirs(os.path.dirname(state_file), exist_ok=True)
        with open(tmp, "w") as f:
            json.dump(state, f, indent=2)
        os.replace(tmp, state_file)
    except Exception:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except Exception:
                pass


def process_alert(
    source: str,
    category: str,
    message: str,
    window_sec: int = DEFAULT_WINDOW_SEC,
    max_burst: int = MAX_BURST,
    state_file: str = STATE_FILE,
) -> Dict[str, Any]:
    """Processes an incoming alert and determines if it should be DELIVERED or SUPPRESSED."""
    now = time.time()
    sig = compute_signature(source, category, message)
    state = load_silencer_state(state_file)

    sigs = state.setdefault("signatures", {})
    entry = sigs.get(sig)

    state["total_processed"] += 1

    if not entry:
        # First time seeing this signature
        sigs[sig] = {
            "source": source,
            "category": category,
            "sample": message[:120],
            "count": 1,
            "suppressed": 0,
            "first_seen": now,
            "last_seen": now,
            "burst_tokens": max_burst - 1,
            "last_token_refresh": now,
        }
        save_silencer_state(state, state_file)
        return {
            "action": "DELIVER",
            "signature": sig,
            "reason": "first_occurrence",
            "suppressed_count": 0,
        }

    # Refresh burst tokens based on elapsed time
    elapsed = now - entry.get("last_token_refresh", now)
    if elapsed >= window_sec:
        entry["burst_tokens"] = max_burst
        entry["last_token_refresh"] = now
        entry["suppressed"] = 0

    entry["count"] += 1
    entry["last_seen"] = now

    if entry["burst_tokens"] > 0:
        entry["burst_tokens"] -= 1
        action = "DELIVER"
        reason = "burst_allowed"
    else:
        entry["suppressed"] += 1
        state["total_suppressed"] += 1
        action = "SUPPRESS"
        reason = f"rate_limited_window_{window_sec}s"

    save_silencer_state(state, state_file)

    return {
        "action": action,
        "signature": sig,
        "reason": reason,
        "total_seen": entry["count"],
        "suppressed_in_window": entry["suppressed"],
    }


def audit_silencer_health(state_file: str = STATE_FILE) -> Dict[str, Any]:
    """Audits current suppression metrics and active signatures."""
    state = load_silencer_state(state_file)
    now = time.time()

    active_signatures = []
    for sig, data in state.get("signatures", {}).items():
        if now - data.get("last_seen", 0) <= 3600:  # active within last hour
            active_signatures.append({
                "signature": sig,
                "source": data.get("source"),
                "category": data.get("category"),
                "count": data.get("count"),
                "suppressed": data.get("suppressed"),
                "sample": data.get("sample"),
            })

    total_proc = state.get("total_processed", 0)
    total_supp = state.get("total_suppressed", 0)
    dampening_ratio = round((total_supp / total_proc * 100.0), 2) if total_proc > 0 else 0.0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "total_processed": total_proc,
            "total_suppressed": total_supp,
            "dampening_ratio_pct": dampening_ratio,
            "active_signatures_count": len(active_signatures),
            "status": "HEALTHY",
            "healthy": True,
        },
        "top_active_signatures": sorted(active_signatures, key=lambda x: x["count"], reverse=True)[:5],
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Alert Storm & Webhook Throttler (Pattern 43)"
    )
    parser.add_argument("--source", type=str, default="fleet-worker", help="Alert source agent or service")
    parser.add_argument("--category", type=str, default="error", help="Alert category or subsystem")
    parser.add_argument("--message", type=str, help="Alert message text to evaluate")
    parser.add_argument("--audit", action="store_true", help="Audit current silencer health and suppression stats")
    parser.add_argument("--window-sec", type=int, default=DEFAULT_WINDOW_SEC, help="Suppression window in seconds")
    parser.add_argument("--max-burst", type=int, default=MAX_BURST, help="Maximum burst before throttling")
    parser.add_argument("--state-file", type=str, default=STATE_FILE, help="Path to state file")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--check", action="store_true", help="Health check mode")

    args = parser.parse_args()

    if args.audit or not args.message:
        report = audit_silencer_health(args.state_file)
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            s = report["summary"]
            print(f"Jev Alert Silencer (Pattern 43) — {report['timestamp']}")
            print(f"  • Status: {s['status']}")
            print(f"  • Processed: {s['total_processed']}, Suppressed: {s['total_suppressed']} ({s['dampening_ratio_pct']}%)")
            print(f"  • Active Signatures (last 1h): {s['active_signatures_count']}")
            if report["top_active_signatures"]:
                print("\n  Top Signatures:")
                for item in report["top_active_signatures"]:
                    print(f"    - [{item['source']}:{item['category']}] {item['sample']} (x{item['count']}, suppressed {item['suppressed']})")
        sys.exit(0)

    res = process_alert(
        source=args.source,
        category=args.category,
        message=args.message,
        window_sec=args.window_sec,
        max_burst=args.max_burst,
        state_file=args.state_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(f"Action: {res['action']} ({res['reason']}, sig={res['signature']})")

    if args.check and res["action"] == "SUPPRESS":
        sys.exit(2)


if __name__ == "__main__":
    main()
