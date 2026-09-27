#!/usr/bin/env python3
"""
fm-jev-stall-guard.py - Jev Long-Run Task Activity Prober & Fake-Stall Dampener

Probes agent seats and worker environments before firing stall alarms.
Detects active execution signals:
  1. Process tree inspection (active compiler, runner, test suite, node/python runtime)
  2. Worktree mtime recency (files created or edited in last 10m)
  3. Git branch/commit recency (last commit in last 15m)
  4. Session transcript file growth (appended in last 5m)

Dampens spurious stall alerts when workers are legitimately busy.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

BUSY_PROCESS_PATTERNS = [
    "playwright",
    "pytest",
    "bun",
    "node",
    "python",
    "cargo",
    "rustc",
    "ffmpeg",
    "verovio",
    "git",
    "make",
    "gcc",
    "g++",
    "chrome",
]

def run_cmd(cmd: List[str], cwd: Optional[str] = None) -> Tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=cwd,
            timeout=5,
            check=False,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return 1, "", str(e)

def find_worktree_for_seat(seat: str, fm_home: Path) -> Optional[Path]:
    # Check treehouse directories
    treehouse_root = Path.home() / ".treehouse"
    if treehouse_root.exists():
        candidates = list(treehouse_root.glob(f"*{seat}*")) + list(treehouse_root.glob(f"*/*/{seat}*"))
        for c in candidates:
            if c.is_dir() and (c / ".git").exists():
                return c

    # Check status file for worktree pointer
    status_file = fm_home / "state" / f"{seat}.status"
    if status_file.exists():
        text = status_file.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if "worktree=" in line:
                wt = line.split("worktree=", 1)[1].strip()
                p = Path(wt)
                if p.is_dir():
                    return p
    return None

def check_process_activity(seat: str, worktree: Optional[Path]) -> List[str]:
    active_procs = []
    rc, stdout, _ = run_cmd(["ps", "-eo", "pid,ppid,args"])
    if rc != 0 or not stdout:
        return active_procs

    processes = {}
    for line in stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            processes[int(fields[0])] = (int(fields[1]), fields[2])
    excluded = set()
    pid = os.getpid()
    while pid and pid not in excluded:
        excluded.add(pid)
        pid = processes.get(pid, (0, ""))[0]
    excluded.add(os.getppid())
    wt_str = str(worktree) if worktree else ""
    for pid, (_, command) in processes.items():
        if pid in excluded:
            continue
        line_l = command.lower()
        if any(pattern in line_l for pattern in BUSY_PROCESS_PATTERNS):
            if (seat and seat.lower() in line_l) or (wt_str and wt_str in command):
                active_procs.append(f"{pid} {command}")
    return active_procs

def check_worktree_mtime(worktree: Path, max_age_seconds: int = 600) -> List[str]:
    recent_files = []
    if not worktree.exists():
        return recent_files

    now = time.time()
    try:
        for root, dirs, files in os.walk(worktree):
            dirs[:] = [d for d in dirs if d not in (".git", "node_modules", ".cache", "tmp")]
            for f in files:
                p = Path(root) / f
                try:
                    mtime = p.stat().st_mtime
                    if now - mtime <= max_age_seconds:
                        recent_files.append(str(p.relative_to(worktree)))
                        if len(recent_files) >= 10:
                            return recent_files
                except OSError:
                    continue
    except Exception:
        pass
    return recent_files

def check_git_commit_recency(worktree: Path, max_age_seconds: int = 900) -> Optional[Dict[str, Any]]:
    if not (worktree / ".git").exists():
        return None

    rc, stdout, _ = run_cmd(["git", "log", "-1", "--format=%ct|%h|%s"], cwd=str(worktree))
    if rc != 0 or not stdout:
        return None

    parts = stdout.split("|", 2)
    if len(parts) >= 3:
        try:
            commit_time = int(parts[0].strip())
            age = int(time.time()) - commit_time
            if age <= max_age_seconds:
                return {
                    "hash": parts[1].strip(),
                    "subject": parts[2].strip(),
                    "age_seconds": age,
                }
        except ValueError:
            pass
    return None

def check_session_transcript(seat: str, max_age_seconds: int = 300) -> Optional[Dict[str, Any]]:
    pi_sessions = Path.home() / ".pi" / "agent" / "sessions"
    if not pi_sessions.exists():
        return None

    # Search for sessions matching seat
    now = time.time()
    for s_dir in pi_sessions.glob(f"*{seat}*"):
        if s_dir.is_dir():
            for f in s_dir.glob("*.jsonl"):
                try:
                    mtime = f.stat().st_mtime
                    age = int(now - mtime)
                    if age <= max_age_seconds:
                        return {
                            "session_file": str(f),
                            "size_bytes": f.stat().st_size,
                            "age_seconds": age,
                        }
                except OSError:
                    continue
    return None

def evaluate_stall(
    seat: str,
    worktree_path: Optional[str] = None,
    fm_home_str: Optional[str] = None,
) -> Dict[str, Any]:
    fm_home = Path(fm_home_str or os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    worktree = Path(worktree_path) if worktree_path else find_worktree_for_seat(seat, fm_home)

    signals: Dict[str, Any] = {}
    active_signals_count = 0

    # 1. Process activity
    procs = check_process_activity(seat, worktree)
    signals["active_processes"] = procs
    if procs:
        active_signals_count += 1

    # 2. Worktree file mtime
    recent_files = []
    if worktree:
        recent_files = check_worktree_mtime(worktree, max_age_seconds=600)
    signals["recent_files_modified"] = recent_files
    if recent_files:
        active_signals_count += 1

    # 3. Git commit activity
    git_commit = None
    if worktree:
        git_commit = check_git_commit_recency(worktree, max_age_seconds=900)
    signals["recent_git_commit"] = git_commit
    if git_commit:
        active_signals_count += 1

    # 4. Session transcript activity
    transcript = check_session_transcript(seat, max_age_seconds=300)
    signals["recent_transcript_growth"] = transcript
    if transcript:
        active_signals_count += 1

    if active_signals_count > 0:
        verdict = "BUSY_ACTIVE_EXECUTION"
        reasons = []
        if procs:
            reasons.append(f"{len(procs)} active background process(es) running")
        if recent_files:
            reasons.append(f"{len(recent_files)} file(s) modified in worktree within 10m")
        if git_commit:
            reasons.append(f"Git commit {git_commit['hash']} authored {git_commit['age_seconds']}s ago")
        if transcript:
            reasons.append(f"Agent transcript active {transcript['age_seconds']}s ago")
    else:
        verdict = "GENUINE_STALL"
        reasons = ["Zero active processes, zero file modifications, zero commits, and zero transcript updates detected."]

    return {
        "seat": seat,
        "worktree": str(worktree) if worktree else None,
        "verdict": verdict,
        "should_dampen": (verdict == "BUSY_ACTIVE_EXECUTION"),
        "active_signals_count": active_signals_count,
        "reasons": reasons,
        "signals": signals,
    }

def format_summary(result: Dict[str, Any]) -> str:
    verdict = result.get("verdict", "UNKNOWN")
    seat = result.get("seat", "")
    lines = []
    if verdict == "BUSY_ACTIVE_EXECUTION":
        lines.append(f"Jev Stall Guard: [STALL_DAMPENED] {seat} is actively executing")
        lines.append(f"Status: BUSY_ACTIVE_EXECUTION (Suppression Recommended)")
        for r in result.get("reasons", []):
            lines.append(f"  • {r}")
    else:
        lines.append(f"Jev Stall Guard: [GENUINE_STALL] {seat} appears stalled")
        lines.append(f"Status: GENUINE_STALL (Alert Authorized)")
        for r in result.get("reasons", []):
            lines.append(f"  • {r}")
    return "\n".join(lines)

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Long-Run Task Activity Prober & Fake-Stall Dampener (Pattern 14)"
    )
    parser.add_argument("--seat", required=True, help="Seat / task identifier (e.g. websites, portal-ops)")
    parser.add_argument("--worktree", default=None, help="Explicit path to seat worktree")
    parser.add_argument("--suppress", action="store_true", help="Return 0 if active execution, 1 if genuine stall")
    parser.add_argument("--json", action="store_true", help="Output JSON format")

    args = parser.parse_args()
    result = evaluate_stall(args.seat, worktree_path=args.worktree)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(format_summary(result))

    if args.suppress:
        # Exit 0 means stall dampened (safe to ignore), Exit 1 means genuine stall
        return 0 if result["should_dampen"] else 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
