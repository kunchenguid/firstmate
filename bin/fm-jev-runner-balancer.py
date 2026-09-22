#!/usr/bin/env python3
"""
fm-jev-runner-balancer.py - Jev Autonomous CI Runner Health & Shard Load Balancer (Pattern 23)

Monitors self-hosted GitHub Actions runner fleets (Covenant Clinic OptiPlexes, home lab daemons,
devbox e2e workers), inspects active workflow runs and matrix shards, detects runner skew,
queue depth, wedged/hung jobs (>20m), and runner communication dropouts. Generates actionable
load balancing telemetry and automated retry/rebalance recommendations to ensure zero-latency
CI throughput across production PR pipelines.

Safety invariants:
- Read-only inspection; NEVER terminates or cancels jobs without explicit command.
- Fails open gracefully if gh CLI or network is unavailable.
- Supports mock data for unit testing, dry-run previews, and structured JSON output.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Dict, List, Any, Optional


def fetch_runners(repo: str, mock_file: Optional[str] = None) -> List[Dict[str, Any]]:
    if mock_file and os.path.exists(mock_file):
        try:
            with open(mock_file, "r") as f:
                data = json.load(f)
                return data.get("runners", [])
        except Exception:
            return []

    try:
        cmd = ["gh", "api", f"repos/{repo}/actions/runners", "--jq", ".runners"]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            return json.loads(result.stdout)
    except Exception:
        pass
    return []


def fetch_active_jobs(repo: str, mock_file: Optional[str] = None) -> List[Dict[str, Any]]:
    if mock_file and os.path.exists(mock_file):
        try:
            with open(mock_file, "r") as f:
                data = json.load(f)
                return data.get("jobs", [])
        except Exception:
            return []

    try:
        cmd = ["gh", "run", "list", "--repo", repo, "--limit", "5", "--json", "databaseId,status,conclusion,workflowName"]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            runs = json.loads(result.stdout)
            active_runs = [r for r in runs if r.get("status") == "in_progress"]
            all_jobs = []
            for r in active_runs:
                run_id = r.get("databaseId")
                job_cmd = ["gh", "run", "view", str(run_id), "--repo", repo, "--json", "jobs"]
                job_res = subprocess.run(job_cmd, capture_output=True, text=True, timeout=15)
                if job_res.returncode == 0:
                    job_data = json.loads(job_res.stdout)
                    all_jobs.extend(job_data.get("jobs", []))
            return all_jobs
    except Exception:
        pass
    return []


def analyze_runners_and_shards(
    runners: List[Dict[str, Any]],
    jobs: List[Dict[str, Any]],
    wedged_threshold_mins: float = 20.0,
) -> Dict[str, Any]:
    now = time.time()

    total_runners = len(runners)
    online_runners = [r for r in runners if r.get("status") == "online"]
    offline_runners = [r for r in runners if r.get("status") != "online"]
    busy_runners = [r for r in online_runners if r.get("busy") is True]
    idle_runners = [r for r in online_runners if r.get("busy") is not True]

    # Pool classifications
    pools: Dict[str, Dict[str, int]] = {
        "portal-ci-linux": {"total": 0, "busy": 0, "idle": 0},
        "portal-e2e": {"total": 0, "busy": 0, "idle": 0},
        "covenant-clinic": {"total": 0, "busy": 0, "idle": 0},
        "other": {"total": 0, "busy": 0, "idle": 0},
    }

    for r in online_runners:
        labels = [lbl.get("name", "") if isinstance(lbl, dict) else str(lbl) for lbl in r.get("labels", [])]
        name = r.get("name", "")
        is_busy = r.get("busy") is True

        target_pool = "other"
        if "portal-ci-linux" in labels:
            target_pool = "portal-ci-linux"
        elif "portal-e2e" in labels:
            target_pool = "portal-e2e"
        elif name.startswith("cvn-runner") or "covenant" in name:
            target_pool = "covenant-clinic"

        pools[target_pool]["total"] += 1
        if is_busy:
            pools[target_pool]["busy"] += 1
        else:
            pools[target_pool]["idle"] += 1

    busy_ratio_pct = (len(busy_runners) / len(online_runners) * 100.0) if online_runners else 0.0

    in_progress_jobs = [j for j in jobs if j.get("status") == "in_progress"]
    queued_jobs = [j for j in jobs if j.get("status") == "queued"]

    wedged_jobs = []
    for j in in_progress_jobs:
        started_str = j.get("startedAt", "")
        if started_str:
            try:
                # Basic ISO parsing
                import datetime
                dt = datetime.datetime.fromisoformat(started_str.replace("Z", "+00:00"))
                elapsed_mins = (datetime.datetime.now(datetime.timezone.utc) - dt).total_seconds() / 60.0
                if elapsed_mins >= wedged_threshold_mins:
                    wedged_jobs.append({
                        "id": j.get("databaseId") or j.get("id"),
                        "name": j.get("name"),
                        "elapsed_minutes": round(elapsed_mins, 1),
                        "runner_name": j.get("runnerName", "unknown"),
                    })
            except Exception:
                pass

    recommendations = []
    if len(queued_jobs) > 0 and len(idle_runners) == 0:
        recommendations.append("scale_runner_capacity_or_dual_pack_daemons")
    if wedged_jobs:
        recommendations.append("investigate_or_retrigger_wedged_matrix_shards")
    if pools["covenant-clinic"]["busy"] > 0 and pools["portal-ci-linux"]["idle"] > 4:
        recommendations.append("rebalance_shards_toward_idle_linux_pool")

    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "fleet_capacity": {
            "total_runners": total_runners,
            "online_runners": len(online_runners),
            "offline_runners": len(offline_runners),
            "busy_runners": len(busy_runners),
            "idle_runners": len(idle_runners),
            "busy_ratio_pct": round(busy_ratio_pct, 1),
        },
        "runner_pools": pools,
        "pipeline_health": {
            "in_progress_jobs": len(in_progress_jobs),
            "queued_jobs": len(queued_jobs),
            "wedged_jobs_count": len(wedged_jobs),
            "wedged_jobs": wedged_jobs,
        },
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Autonomous CI Runner Health & Shard Load Balancer (Pattern 23)"
    )
    parser.add_argument(
        "--repo",
        default="ArcsHealth/Portal",
        help="Target GitHub repository (default: ArcsHealth/Portal)",
    )
    parser.add_argument(
        "--mock-data",
        help="Path to mock JSON file containing runners and jobs for testing",
    )
    parser.add_argument(
        "--wedged-threshold",
        type=float,
        default=20.0,
        help="Job execution minutes above which shard is considered wedged (default: 20.0)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output structured JSON telemetry",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate scan without automated balancing actions",
    )

    args = parser.parse_args()

    runners = fetch_runners(args.repo, mock_file=args.mock_data)
    jobs = fetch_active_jobs(args.repo, mock_file=args.mock_data)

    report = analyze_runners_and_shards(
        runners=runners,
        jobs=jobs,
        wedged_threshold_mins=args.wedged_threshold,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        fc = report["fleet_capacity"]
        ph = report["pipeline_health"]
        print(f"Jev CI Runner Health & Shard Balancer (Pattern 23):")
        print(f"  • Runners Online: {fc['online_runners']} / {fc['total_runners']} ({fc['busy_ratio_pct']}% busy)")
        print(f"  • Busy Runners: {fc['busy_runners']} | Idle Runners: {fc['idle_runners']}")
        print(f"  • Jobs In Progress: {ph['in_progress_jobs']} | Queued Jobs: {ph['queued_jobs']}")
        print(f"  • Wedged Shards (> {args.wedged_threshold}m): {ph['wedged_jobs_count']}")

        print("\nRunner Pool Allocations:")
        for pool, stats in report["runner_pools"].items():
            print(f"  ↳ {pool:<18}: {stats['busy']} busy / {stats['idle']} idle (Total: {stats['total']})")

        if ph["wedged_jobs"]:
            print("\n⚠ Wedged Jobs Detected:")
            for w in ph["wedged_jobs"]:
                print(f"  ↳ Job #{w['id']} ({w['name']}): elapsed {w['elapsed_minutes']}m on runner {w['runner_name']}")

        if report["recommendations"]:
            print("\nBalancing Recommendations:")
            for rec in report["recommendations"]:
                print(f"  ↳ {rec}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
