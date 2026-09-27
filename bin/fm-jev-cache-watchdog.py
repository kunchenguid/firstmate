#!/usr/bin/env python3
"""
fm-jev-cache-watchdog.py - Jev Model Context & Prompt Cache Degradation Watchdog (Pattern 22)

Monitors autonomous agent sessions (Firstmate w1:pA, Second Mates, workers across Herdr panes),
inspects prompt cache hit rates (cacheRead / (cacheRead + input)), context window occupancy,
and wake queue pressure. Flags cache degradation (<95%) or context saturation (>60%),
generating structured telemetry and alerting supervisors to trigger timely context
compaction or wake-drain before token thrashing or harness quota exhaustion occurs.

Safety invariants:
- Read-only inspection; NEVER mutates or truncates active session files directly.
- Handles partial, streaming, or malformed JSONL records gracefully (fails open).
- Supports dry-run and JSON telemetry modes.
- Fully non-blocking and idempotent.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Dict, List, Any, Optional


CONTEXT_LIMITS = {
    "grok-4.5": 500000,
    "grok-4.5-medium": 500000,
    "claude-3-7-sonnet": 200000,
    "claude-3-5-sonnet": 200000,
    "gemini-2.5-pro": 1000000,
    "gemini-2.5-flash": 1000000,
    "muse-spark-1.2-contributor": 1000000,
    "default": 200000,
}


def get_context_limit(model_name: str) -> int:
    for k, v in CONTEXT_LIMITS.items():
        if k in model_name.lower():
            return v
    return CONTEXT_LIMITS["default"]


def inspect_session_file(filepath: Path) -> Optional[Dict[str, Any]]:
    """
    Parses a session JSONL file to extract the latest turn's usage and cache metrics.
    """
    if not filepath.is_file() or filepath.stat().st_size == 0:
        return None

    last_usage_record = None
    agent_info = {
        "session_path": str(filepath),
        "filename": filepath.name,
        "mtime": filepath.stat().st_mtime,
        "file_size_bytes": filepath.stat().st_size,
    }

    try:
        # Read the tail of the file to find the latest assistant usage block
        # For efficiency on large session files, read last 256KB
        file_size = filepath.stat().st_size
        bytes_to_read = min(file_size, 262144)
        with open(filepath, "rb") as f:
            if file_size > bytes_to_read:
                f.seek(file_size - bytes_to_read)
            raw_data = f.read()

        text = raw_data.decode("utf-8", errors="ignore")
        lines = text.splitlines()

        for line in reversed(lines):
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                data = json.loads(line)
                if data.get("type") == "message" and "message" in data:
                    msg = data["message"]
                    if msg.get("role") == "assistant" and "usage" in msg:
                        last_usage_record = msg
                        break
            except Exception:
                continue

    except Exception:
        return None

    if not last_usage_record:
        return None

    usage = last_usage_record.get("usage", {})
    input_tokens = usage.get("input", 0)
    output_tokens = usage.get("output", 0)
    cache_read = usage.get("cacheRead", 0)
    cache_write = usage.get("cacheWrite", 0)
    total_tokens = usage.get("totalTokens", input_tokens + output_tokens + cache_read)
    model = last_usage_record.get("model", "unknown")
    provider = last_usage_record.get("provider", "unknown")

    total_prompt_tokens = input_tokens + cache_read
    if total_prompt_tokens > 0:
        cache_hit_rate = (cache_read / total_prompt_tokens) * 100.0
    else:
        cache_hit_rate = 100.0

    context_limit = get_context_limit(model)
    context_usage_pct = (total_tokens / context_limit) * 100.0 if context_limit > 0 else 0.0

    return {
        **agent_info,
        "model": model,
        "provider": provider,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_read_tokens": cache_read,
        "cache_write_tokens": cache_write,
        "total_tokens": total_tokens,
        "context_limit": context_limit,
        "cache_hit_rate_pct": round(cache_hit_rate, 2),
        "context_usage_pct": round(context_usage_pct, 2),
        "last_turn_timestamp": last_usage_record.get("timestamp", 0),
    }


def scan_sessions(
    roots: List[str],
    max_age_hours: float = 24.0,
    threshold_hit_rate: float = 95.0,
    threshold_context_pct: float = 60.0,
) -> Dict[str, Any]:
    now = time.time()
    max_age_secs = max_age_hours * 3600.0

    report: Dict[str, Any] = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "roots_scanned": roots,
        "sessions_inspected": 0,
        "active_sessions": [],
        "degradation_alerts": [],
        "context_bloat_alerts": [],
        "healthy_sessions": 0,
        "summary": {},
    }

    found_files: List[Path] = []
    for root_str in roots:
        root = Path(root_str).expanduser()
        if not root.exists():
            continue
        for p in root.glob("**/*.jsonl"):
            try:
                if (now - p.stat().st_mtime) <= max_age_secs:
                    found_files.append(p)
            except Exception:
                continue

    for p in found_files:
        stats = inspect_session_file(p)
        if not stats:
            continue

        report["sessions_inspected"] += 1
        session_entry = {
            "session": stats["filename"],
            "model": stats["model"],
            "cache_hit_rate_pct": stats["cache_hit_rate_pct"],
            "context_usage_pct": stats["context_usage_pct"],
            "total_tokens": stats["total_tokens"],
            "context_limit": stats["context_limit"],
            "age_minutes": round((now - stats["mtime"]) / 60.0, 1),
            "path": stats["session_path"],
        }
        report["active_sessions"].append(session_entry)

        alert_flags = []
        if stats["cache_hit_rate_pct"] < threshold_hit_rate:
            alert = {
                "session": stats["filename"],
                "model": stats["model"],
                "cache_hit_rate_pct": stats["cache_hit_rate_pct"],
                "threshold_pct": threshold_hit_rate,
                "deficit_pct": round(threshold_hit_rate - stats["cache_hit_rate_pct"], 2),
                "remedy": "drain_wake_queue_and_compact_prompt",
                "path": stats["session_path"],
            }
            report["degradation_alerts"].append(alert)
            alert_flags.append("CACHE_DEGRADED")

        if stats["context_usage_pct"] > threshold_context_pct:
            alert = {
                "session": stats["filename"],
                "model": stats["model"],
                "context_usage_pct": stats["context_usage_pct"],
                "threshold_pct": threshold_context_pct,
                "total_tokens": stats["total_tokens"],
                "context_limit": stats["context_limit"],
                "remedy": "trigger_session_compaction_or_cycle_seat",
                "path": stats["session_path"],
            }
            report["context_bloat_alerts"].append(alert)
            alert_flags.append("CONTEXT_BLOATED")

        if not alert_flags:
            report["healthy_sessions"] += 1

    report["summary"] = {
        "total_active": report["sessions_inspected"],
        "healthy_count": report["healthy_sessions"],
        "cache_degradation_alerts": len(report["degradation_alerts"]),
        "context_bloat_alerts": len(report["context_bloat_alerts"]),
    }

    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Model Context & Prompt Cache Degradation Watchdog (Pattern 22)"
    )
    parser.add_argument(
        "--roots",
        nargs="+",
        default=[
            str(Path.home() / ".pi" / "agent" / "sessions"),
        ],
        help="Root directories containing agent session JSONL logs",
    )
    parser.add_argument(
        "--threshold-hit-rate",
        type=float,
        default=95.0,
        help="Prompt cache hit rate percentage below which degradation is alerted (default: 95.0)",
    )
    parser.add_argument(
        "--threshold-context-pct",
        type=float,
        default=60.0,
        help="Context window occupancy percentage above which bloat is alerted (default: 60.0)",
    )
    parser.add_argument(
        "--max-age-hours",
        type=float,
        default=12.0,
        help="Maximum session file modification age in hours to inspect (default: 12.0)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output structured JSON telemetry",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Scan and report telemetry without taking automated actions",
    )

    args = parser.parse_args()

    report = scan_sessions(
        roots=args.roots,
        max_age_hours=args.max_age_hours,
        threshold_hit_rate=args.threshold_hit_rate,
        threshold_context_pct=args.threshold_context_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Jev Model Context & Prompt Cache Watchdog (Pattern 22):")
        print(f"  • Sessions Inspected: {report['sessions_inspected']}")
        print(f"  • Healthy Sessions: {report['healthy_sessions']}")
        print(f"  • Cache Degradation Alerts: {len(report['degradation_alerts'])}")
        print(f"  • Context Bloat Alerts: {len(report['context_bloat_alerts'])}")

        if report["active_sessions"]:
            print("\nActive Fleet Sessions (Recent Turns):")
            for s in report["active_sessions"]:
                status_icon = "✓"
                is_degraded = s["cache_hit_rate_pct"] < args.threshold_hit_rate
                is_bloated = s["context_usage_pct"] > args.threshold_context_pct
                if is_degraded or is_bloated:
                    status_icon = "⚠"
                print(
                    f"  {status_icon} {s['session'][:30]}... | Model: {s['model']} | "
                    f"CH: {s['cache_hit_rate_pct']}% | Ctx: {s['context_usage_pct']}% "
                    f"({s['total_tokens']}/{s['context_limit']}) | Age: {s['age_minutes']}m"
                )

        if report["degradation_alerts"]:
            print("\n⚠ Cache Degradation Warnings:")
            for a in report["degradation_alerts"]:
                print(
                    f"  ↳ {a['session']}: CH={a['cache_hit_rate_pct']}% < {a['threshold_pct']}% "
                    f"(Deficit: -{a['deficit_pct']}%) => Action: {a['remedy']}"
                )

        if report["context_bloat_alerts"]:
            print("\n⚠ Context Bloat Warnings:")
            for a in report["context_bloat_alerts"]:
                print(
                    f"  ↳ {a['session']}: Ctx={a['context_usage_pct']}% > {a['threshold_pct']}% "
                    f"({a['total_tokens']}/{a['context_limit']} tokens) => Action: {a['remedy']}"
                )

    return 0


if __name__ == "__main__":
    sys.exit(main())
