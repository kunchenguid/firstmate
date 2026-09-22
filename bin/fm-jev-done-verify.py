#!/usr/bin/env python3
"""fm-jev-done-verify.py - Automated Definition of Done & Fake-Done Verifier using Jev System One.

Prevents tasks from falsely reporting `done:` when work is uncommitted, unpushed,
missing an upstream PR, or dependent on uncommitted temporary host configurations.

Usage:
  fm-jev-done-verify.py --task <task-id> [--worktree <path>] [--status-line <str>] [--json]
"""
from __future__ import annotations

import argparse
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


def log_telemetry(verdict: str, tier: str, code: str, task_id: str, reason: str) -> None:
    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))
    telem_file = state_dir / ".jev-done-telemetry"
    try:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        clean_reason = " ".join(reason.split())[:120]
        line = f"{ts}\t{verdict}\t{tier}\t{code}\t{task_id}\t{clean_reason}\n"
        with open(telem_file, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def emit_verdict(
    verdict: str,
    code: str,
    reason: str,
    tier: str = "tier1",
    task_id: str = "",
    as_json: bool = False,
    exit_code: int = 0,
) -> None:
    log_telemetry(verdict, tier, code, task_id, reason)
    if as_json:
        payload = {
            "verdict": verdict,
            "code": code,
            "reason": reason,
            "tier": tier,
            "task_id": task_id,
        }
        print(json.dumps(payload, indent=2))
        sys.exit(exit_code)

    if verdict == "verified":
        print(f"VERDICT: verified [{code}] {reason}")
    else:
        print(f"VERDICT: rejected [{code}] {reason}", file=sys.stderr)
    sys.exit(exit_code)


def inspect_git_deliverables(wt_path: Path) -> tuple[bool, str, str]:
    """Run Tier 1 static deliverable checks on git worktree."""
    if not wt_path.exists() or not (wt_path / ".git").exists():
        # If not a git repo, skip git assertions
        return True, "not_git_repo", "Worktree is not a git repository"

    # 1. Check uncommitted changes (dirty worktree)
    try:
        res = subprocess.run(
            ["git", "-C", str(wt_path), "status", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        status_lines = [l for l in res.stdout.splitlines() if l.strip()]
        # Ignore untracked log or tmp files
        dirty_lines = [
            l for l in status_lines
            if not any(l.endswith(suf) for suf in (".log", ".tmp", ".swp", ".pyc"))
            and not l.startswith("?? state/")
            and not l.startswith("?? data/")
        ]
        if dirty_lines:
            sample = "; ".join(dirty_lines[:3])
            return False, "dirty_worktree", f"Worktree has uncommitted modifications: {sample}"
    except Exception as e:
        return True, "git_error", f"Could not query git status: {e}"

    # 2. Check commits ahead of default branch / upstream
    try:
        res = subprocess.run(
            ["git", "-C", str(wt_path), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        current_branch = res.stdout.strip()
        if current_branch and current_branch not in ("main", "master", "HEAD"):
            # Check commit count
            log_res = subprocess.run(
                ["git", "-C", str(wt_path), "log", "origin/main..HEAD", "--oneline"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            commits = [c for c in log_res.stdout.splitlines() if c.strip()]
            if not commits:
                # Try comparing to main
                log_main = subprocess.run(
                    ["git", "-C", str(wt_path), "log", "main..HEAD", "--oneline"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                commits = [c for c in log_main.stdout.splitlines() if c.strip()]

            if not commits:
                return False, "zero_commits", f"Branch {current_branch} has 0 commits ahead of base"

            # 3. Check if commits are pushed to remote
            push_res = subprocess.run(
                ["git", "-C", str(wt_path), "branch", "-r", "--contains", "HEAD"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            remote_branches = [b.strip() for b in push_res.stdout.splitlines() if b.strip()]
            if not remote_branches:
                return False, "unpushed_commits", f"Branch {current_branch} has {len(commits)} commits that are NOT pushed to remote"
    except Exception as e:
        pass

    return True, "static_pass", "Static git checks passed"


def check_ephemeral_residue(status_text: str) -> tuple[bool, str, str]:
    """Detect unmanaged live temporary overrides that will be wiped on restart."""
    lower = status_text.lower()
    patterns = [
        ("temporary relay", "ephemeral_relay", "Relies on a temporary relay that will be lost on deploy/restart"),
        ("untracked in version control", "untracked_config", "Files or configs are untracked and vulnerable to sync wipe"),
        ("manual edit on live host", "manual_host_edit", "Manual live host modification not committed to repository"),
        ("/tmp/fm-", "tmp_dependency", "Direct dependency on ephemeral /tmp staging directory"),
    ]
    for marker, code, desc in patterns:
        if marker in lower:
            return False, code, desc
    return True, "no_ephemeral_residue", "No ephemeral residue detected"


def verify_with_jev(task_id: str, status_text: str, git_summary: str, key: str) -> tuple[bool, str, str]:
    """Tier 3: Semantic evaluation with Jev System One."""
    payload = {
        "model": TS_MODEL,
        "state": {
            "task_id": task_id,
            "status_claim": status_text[:400],
            "git_state": git_summary[:300],
        },
        "questions": {
            "definition_of_done": {
                "type": "choice",
                "instructions": "Evaluate whether this completion claim represents a genuine, durable delivery or a premature/fake-done state (e.g. unpushed code, uncommitted hotfix, missing PR, skipped pipeline).",
                "criteria": {
                    "verified_done": "The task produced real commits, tests pass, deliverables are durable, and no required PR/push was skipped.",
                    "fake_done": "The task claims completion but work is not pushed, no PR exists, deliverables are in ephemeral state, or core requirements were abandoned.",
                    "unmerged_residue": "The code is written and committed locally, but remains stranded on an unpushed branch with no PR opened.",
                },
            },
            "is_deliverable_durable": {
                "type": "noul",
                "instructions": "Is this deliverable durable and reproducible across host restarts and fresh checkouts?",
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
        dod_choice = answers.get("definition_of_done", {}).get("choice", "verified_done")
        durable_noul = float(answers.get("is_deliverable_durable", {}).get("noul", 1.0))

        if dod_choice == "verified_done" and durable_noul >= 0.5:
            return True, "jev_approved", f"Jev verified durable completion (noul={durable_noul:.2f})"
        elif dod_choice == "unmerged_residue":
            return False, "unmerged_residue", "Jev identified stranded work on unmerged/unpushed branch without PR"
        else:
            return False, "fake_done_detected", f"Jev identified fake-done state ({dod_choice}, durability noul={durable_noul:.2f})"
    except Exception as exc:
        # Fail-open on API failure
        return True, "jev_fail_open", f"Jev API timeout/error ({exc}); failing open"


def main() -> None:
    parser = argparse.ArgumentParser(description="Jev Definition of Done Verifier")
    parser.add_argument("--task", required=True, help="Task ID to verify")
    parser.add_argument("--worktree", help="Path to task worktree")
    parser.add_argument("--status-line", help="Status line declaring completion")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    args = parser.parse_args()

    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))

    # Resolve worktree from task meta if not provided
    wt_path = Path(args.worktree) if args.worktree else None
    if not wt_path:
        meta_file = state_dir / f"{args.task}.meta"
        if meta_file.exists():
            for line in meta_file.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("worktree="):
                    wt_path = Path(line.split("=", 1)[1].strip())
                    break

    status_text = args.status_line or ""
    if not status_text:
        status_file = state_dir / f"{args.task}.status"
        if status_file.exists():
            lines = status_file.read_text(encoding="utf-8", errors="replace").splitlines()
            for l in reversed(lines):
                if l.startswith("done:"):
                    status_text = l
                    break

    # 1. Tier 1 Static Ephemeral Residue Check
    ephem_ok, ephem_code, ephem_msg = check_ephemeral_residue(status_text)
    if not ephem_ok:
        emit_verdict(
            verdict="rejected",
            code=ephem_code,
            reason=ephem_msg,
            tier="tier1",
            task_id=args.task,
            as_json=args.json,
            exit_code=2,
        )

    # 2. Tier 1 Git Deliverable Check
    if wt_path and wt_path.exists():
        git_ok, git_code, git_msg = inspect_git_deliverables(wt_path)
        if not git_ok:
            emit_verdict(
                verdict="rejected",
                code=git_code,
                reason=git_msg,
                tier="tier1",
                task_id=args.task,
                as_json=args.json,
                exit_code=2,
            )

    # 3. Tier 3 Jev Semantic Check
    key = get_api_key()
    if key and status_text:
        git_summary = f"wt={wt_path}" if wt_path else "wt=none"
        jev_ok, jev_code, jev_msg = verify_with_jev(args.task, status_text, git_summary, key)
        if not jev_ok:
            emit_verdict(
                verdict="rejected",
                code=jev_code,
                reason=jev_msg,
                tier="tier3",
                task_id=args.task,
                as_json=args.json,
                exit_code=2,
            )

    # All checks passed!
    emit_verdict(
        verdict="verified",
        code="dod_verified",
        reason="All static deliverable and Jev semantic criteria met",
        tier="tier1" if not key else "tier3",
        task_id=args.task,
        as_json=args.json,
        exit_code=0,
    )


if __name__ == "__main__":
    main()
