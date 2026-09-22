#!/usr/bin/env python3
"""
fm-jev-worker-reaper.py - Jev System One Dead Worker Auto-Reaper & Endpoint Reclaimer.

Detects dead or failed child workers (ship/scout) whose Herdr panes and worktree
records remain allocated, blocking replacement spawns.
Safely reaps leaked processes, tears down unlanded failed worktrees, and reclaims endpoints.

Usage:
  bin/fm-jev-worker-reaper.py --check
  bin/fm-jev-worker-reaper.py --reap [--target <task_id>]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def parse_meta_file(meta_path: Path) -> dict:
    data = {}
    try:
        for line in meta_path.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    except Exception:
        pass
    return data


def get_live_panes(session: str = "firstmate") -> set[str] | None:
    """Get all live pane IDs in sub-second time via herdr pane list."""
    try:
        res = subprocess.run(
            ["herdr", "--session", session, "pane", "list"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if res.returncode == 0:
            data = json.loads(res.stdout)
            panes = data["result"]["panes"]
            if not isinstance(panes, list) or any(not isinstance(p, dict) or not p.get("pane_id") for p in panes):
                raise ValueError("Invalid pane list")
            return {p.get("pane_id") for p in panes if p.get("pane_id")}
        print(f"Pane inspection failed for {session}: {res.stderr.strip()}", file=sys.stderr)
    except Exception as exc:
        print(f"Pane inspection failed for {session}: {exc}", file=sys.stderr)
    return None


def scan_dead_workers(state_dirs: list[Path], target_id: str | None = None) -> list[dict]:
    dead_workers = []
    live_sessions = {}
    now = time.time()

    for s_dir in state_dirs:
        if not s_dir.exists():
            continue
        for meta_f in s_dir.glob("*.meta"):
            task_id = meta_f.stem
            if target_id and task_id != target_id:
                continue

            # Only inspect files modified within the last 7 days
            try:
                if now - meta_f.stat().st_mtime > 7 * 86400 and not target_id:
                    continue
            except Exception:
                continue

            meta = parse_meta_file(meta_f)
            kind = meta.get("kind", "unknown")
            # NEVER reap persistent secondmate seats
            if kind == "secondmate":
                continue

            # Skip completed tasks
            status_f = s_dir / f"{task_id}.status"
            if status_f.exists():
                try:
                    st_head = status_f.read_text(encoding="utf-8", errors="replace")[:100]
                    if st_head.startswith("done:"):
                        continue
                except Exception:
                    pass

            pane_id = meta.get("herdr_pane_id")
            session = meta.get("herdr_session", "firstmate")
            wt = meta.get("worktree")
            harness = meta.get("harness")

            if not pane_id or not wt:
                continue

            if session not in live_sessions:
                live_sessions[session] = get_live_panes(session)
            live_panes = live_sessions[session]
            if live_panes is None:
                continue

            # If pane_id is not in live_panes, the pane is dead/closed
            if pane_id not in live_panes:
                dead_workers.append({
                    "task_id": task_id,
                    "meta_path": str(meta_f),
                    "home_dir": str(s_dir.parent),
                    "pane_id": pane_id,
                    "session": session,
                    "worktree": wt,
                    "harness": harness,
                    "reason": "pane_already_closed_meta_stale",
                })
                continue

            # If pane is live, inspect pane content quickly
            is_dead = False
            try:
                res = subprocess.run(
                    ["herdr", "--session", session, "pane", "read", pane_id, "--lines", "12"],
                    capture_output=True,
                    text=True,
                    timeout=2,
                    check=False,
                )
                if res.returncode == 0:
                    pane_content = res.stdout
                    has_prompt = any(p in pane_content for p in [" ❯", " ➜", "$ ", "# "])
                    has_spinner = any(s in pane_content for s in ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", "Working", "Thinking"])
                    if "Error: 429" in pane_content or "Insufficient balance" in pane_content:
                        is_dead = True
                    elif has_prompt and not has_spinner:
                        is_dead = True
            except Exception:
                pass

            if is_dead:
                # Check worktree dirty
                wt_dirty = False
                if wt and Path(wt).exists():
                    try:
                        res = subprocess.run(
                            ["git", "-C", wt, "status", "--porcelain"],
                            capture_output=True,
                            text=True,
                            timeout=2,
                            check=False,
                        )
                        if res.stdout.strip():
                            wt_dirty = True
                    except Exception:
                        pass

                if not wt_dirty:
                    dead_workers.append({
                        "task_id": task_id,
                        "meta_path": str(meta_f),
                        "home_dir": str(s_dir.parent),
                        "pane_id": pane_id,
                        "session": session,
                        "worktree": wt,
                        "harness": harness,
                        "reason": "429_or_exited_at_shell_prompt",
                    })

    return dead_workers


def reap_worker(worker: dict) -> dict:
    home_dir = worker["home_dir"]
    task_id = worker["task_id"]
    teardown_bin = Path(home_dir) / "bin" / "fm-teardown.sh"
    session = worker["session"]
    pane_id = worker["pane_id"]

    actions_taken = []

    # 1. Run teardown if available
    if teardown_bin.exists():
        try:
            res = subprocess.run(
                ["bash", str(teardown_bin), task_id],
                cwd=home_dir,
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            actions_taken.append(f"teardown_rc_{res.returncode}")
            if res.returncode != 0:
                return {"task_id": task_id, "actions": actions_taken, "reclaimed": False}
        except Exception as e:
            actions_taken.append(f"teardown_error: {e}")
            return {"task_id": task_id, "actions": actions_taken, "reclaimed": False}
    else:
        return {"task_id": task_id, "actions": ["teardown_missing"], "reclaimed": False}

    # 2. Close Herdr pane
    try:
        res = subprocess.run(
            ["herdr", "--session", session, "pane", "close", pane_id],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        actions_taken.append(f"pane_close_rc_{res.returncode}")
        if res.returncode != 0:
            return {"task_id": task_id, "actions": actions_taken, "reclaimed": False}
    except Exception as e:
        actions_taken.append(f"pane_close_error: {e}")
        return {"task_id": task_id, "actions": actions_taken, "reclaimed": False}

    # 3. Clean up stale meta if worktree is gone
    meta_path = Path(worker["meta_path"])
    wt_path = Path(worker.get("worktree", ""))
    if meta_path.exists() and not wt_path.exists():
        try:
            meta_path.unlink()
            actions_taken.append("stale_meta_unlinked")
        except Exception:
            pass

    return {
        "task_id": task_id,
        "actions": actions_taken,
        "reclaimed": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Jev Dead Worker Auto-Reaper & Endpoint Reclaimer")
    parser.add_argument("--check", action="store_true", help="Scan for dead workers without reaping")
    parser.add_argument("--reap", action="store_true", help="Reap dead workers and reclaim endpoints")
    parser.add_argument("--target", type=str, help="Target specific task ID")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    args = parser.parse_args()

    # Collect state directories
    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dirs = [fm_root / "state"]
    treehouse = Path("/home/jon/.treehouse")
    if treehouse.exists():
        for d in treehouse.glob("*/14/firstmate/state"):
            state_dirs.append(d)

    dead_workers = scan_dead_workers(state_dirs, target_id=args.target)

    if args.reap:
        results = [reap_worker(w) for w in dead_workers]
        reclaimed = sum(r["reclaimed"] for r in results)
        if args.json:
            print(json.dumps({"reaped": results, "count": reclaimed}, indent=2))
        else:
            print(f"Reaped {reclaimed} dead worker(s) and reclaimed endpoints.")
            for r in results:
                print(f"  ✓ {r['task_id']}: {', '.join(r['actions'])}")
        return 0 if reclaimed == len(results) else 1

    if args.json:
        print(json.dumps({"dead_workers": dead_workers, "count": len(dead_workers)}, indent=2))
    else:
        print(f"Scanned active supervisor homes: found {len(dead_workers)} dead worker(s) holding endpoints.")
        for w in dead_workers:
            print(f"  ! {w['task_id']} holding {w['pane_id']} ({w['worktree']})")

    return 0 if len(dead_workers) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
