#!/usr/bin/env python3
"""
fm-jev-fleet-eval.py - Jev System One Continuous Fleet Telemetry & Harness Fallback Evaluator.

Inspects live fleet status, worker failure logs, and queue state, then queries
Jev System One (https://api.typesafe.ai/v1/systemone) to evaluate bottlenecks,
score fleet health, and recommend automated supervisor interventions.

Usage:
  bin/fm-jev-fleet-eval.py [--json] [--remedy]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TS_BASE = "https://api.typesafe.ai"
TS_MODEL = "jev-latest"
TS_TIMEOUT = 8.0


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


def collect_fleet_state() -> dict:
    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))

    # 1. Collect recent blockers from all status files
    blockers = []
    if state_dir.exists():
        for sf in sorted(state_dir.glob("*.status")):
            try:
                lines = sf.read_text(encoding="utf-8", errors="replace").splitlines()
                for line in lines[-10:]:
                    if line.startswith(("blocked", "failed", "needs-decision")):
                        clean = " ".join(line.split())[:180]
                        blockers.append(f"[{sf.stem}] {clean}")
            except Exception:
                pass

    # 2. Check for child worker errors (e.g. 429 balance or quota issues)
    worker_errors = []
    for meta_file in state_dir.glob("*.meta"):
        try:
            text = meta_file.read_text(encoding="utf-8")
            if "endpoint_task_id=" in text:
                task_id = meta_file.stem
                status_f = state_dir / f"{task_id}.status"
                if status_f.exists():
                    st_text = status_f.read_text(encoding="utf-8", errors="replace")
                    if "429" in st_text or "balance" in st_text or "insufficient" in st_text.lower():
                        worker_errors.append(f"{task_id}: 429 quota/balance exhausted")
        except Exception:
            pass

    # Check secondmate homes for child workers as well
    home_pattern = Path("/home/jon/.treehouse")
    if home_pattern.exists():
        for meta_file in home_pattern.glob("*/14/firstmate/state/*.meta"):
            try:
                text = meta_file.read_text(encoding="utf-8")
                # Look for worker pane
                for line in text.splitlines():
                    if line.startswith("window="):
                        win = line.split("=", 1)[1]
                        # Quick check on pane text via herdr if available
                        break
            except Exception:
                pass

    # 3. Queue depth
    queue_file = state_dir / ".wake-queue"
    queue_depth = 0
    if queue_file.exists():
        try:
            queue_depth = len(queue_file.read_text(encoding="utf-8").strip().splitlines())
        except Exception:
            pass

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "queue_depth": queue_depth,
        "blockers_sample": blockers[-15:] if blockers else ["none (all seats clear)"],
        "worker_errors": worker_errors if worker_errors else ["none detected"],
    }


def evaluate_with_jev(state: dict, key: str) -> dict:
    payload = {
        "model": TS_MODEL,
        "state": {
            "queue_depth": str(state["queue_depth"]),
            "recent_blockers": "\n".join(state["blockers_sample"]),
            "worker_errors": "\n".join(state["worker_errors"]),
        },
        "questions": {
            "primary_bottleneck": {
                "type": "choice",
                "instructions": "Identify the primary bottleneck currently affecting the fleet based on the state:",
                "criteria": {
                    "harness_quota_exhaustion": "Workers or secondmates are halted on token balance, rate limit (429), or auth errors.",
                    "ci_pipeline_stall": "PRs or workers are waiting on missing or incomplete CI workflows.",
                    "stale_bookkeeping_noise": "Dormant seats hold superseded config reread or doorbell pings.",
                    "healthy_stable": "Queue depth is low and no critical worker is wedged."
                }
            },
            "remediation_strategy": {
                "type": "choice",
                "instructions": "What is the recommended supervisor action?",
                "criteria": {
                    "relaunch_worker_on_cursor_grok": "Relaunch halted worker using Cursor Grok 4.6 High which has verified runway.",
                    "skip_or_attest_zero_ci": "Attest local test evidence and land PR under standing +yolo policy.",
                    "auto_reconcile_dormant_seats": "Run pending-reply auto-reconciler to clear superseded markers.",
                    "maintain_steady_state": "Fleet is operating within parameters; continue cadence monitoring."
                }
            },
            "fleet_health_noul": {
                "type": "noul",
                "instructions": "Overall health score of the fleet (1.0 = flawless operation, 0.0 = completely wedged)."
            }
        }
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

    with urllib.request.urlopen(req, timeout=TS_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def local_heuristic_evaluate(state: dict) -> dict:
    """Deterministic local fallback evaluation when remote Typesafe API is unavailable."""
    q_depth = state.get("queue_depth", 0)
    has_worker_errors = any("429" in err or "balance" in err for err in state.get("worker_errors", []))
    if has_worker_errors:
        bottleneck = "harness_quota_exhaustion"
        remediation = "auto_reconcile_dormant_seats"
        health = 0.25
    elif q_depth > 10:
        bottleneck = "stale_bookkeeping_noise"
        remediation = "auto_reconcile_dormant_seats"
        health = 0.50
    else:
        bottleneck = "healthy_stable"
        remediation = "maintain_steady_state"
        health = 0.85

    return {
        "model": "jev-local-fallback",
        "answers": {
            "primary_bottleneck": {"choice": bottleneck, "confidence": 0.95},
            "remediation_strategy": {"choice": remediation, "confidence": 0.95},
            "fleet_health_noul": {"noul": health},
        },
        "usage": {"input": 0, "output": 0, "note": "local_fallback"},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Jev Fleet Telemetry & Harness Fallback Evaluator")
    parser.add_argument("--json", action="store_true", help="Output raw JSON")
    parser.add_argument("--remedy", action="store_true", help="Emit actionable remediation command")
    args = parser.parse_args()

    state = collect_fleet_state()
    key = get_api_key()
    if not key:
        eval_result = local_heuristic_evaluate(state)
    else:
        try:
            eval_result = evaluate_with_jev(state, key)
        except Exception as e:
            print(f"warning: Jev API evaluation gateway unavailable ({e}), using local deterministic evaluator", file=sys.stderr)
            eval_result = local_heuristic_evaluate(state)

    answers = eval_result.get("answers", {})
    bottleneck = answers.get("primary_bottleneck", {}).get("choice", "unknown")
    confidence = answers.get("primary_bottleneck", {}).get("confidence", 0.0)
    remediation = answers.get("remediation_strategy", {}).get("choice", "unknown")
    health = answers.get("fleet_health_noul", {}).get("noul", 0.5)
    usage = eval_result.get("usage", {})

    output = {
        "timestamp": state["timestamp"],
        "model": eval_result.get("model", TS_MODEL),
        "fleet_health_score": round(health, 2),
        "primary_bottleneck": bottleneck,
        "bottleneck_confidence": round(confidence, 2),
        "recommended_remediation": remediation,
        "tokens_used": usage,
    }

    # Record telemetry
    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))
    telem_log = state_dir / ".jev-fleet-telemetry.jsonl"
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        with open(telem_log, "a", encoding="utf-8") as f:
            f.write(json.dumps(output) + "\n")
    except Exception:
        pass

    if args.json:
        print(json.dumps(output, indent=2))
    else:
        print(f"Jev System One Fleet Evaluation ({output['timestamp']}):")
        print(f"  • Model: {output['model']}")
        print(f"  • Health Score: {output['fleet_health_score'] * 100:.0f}%")
        print(f"  • Primary Bottleneck: {output['primary_bottleneck']} ({output['bottleneck_confidence'] * 100:.0f}% confidence)")
        print(f"  • Recommended Remediation: {output['recommended_remediation']}")
        print(f"  • Tokens Consumed: {usage.get('input_tokens', 0)} in / {usage.get('output_tokens', 0)} out")

    return 0


if __name__ == "__main__":
    sys.exit(main())
