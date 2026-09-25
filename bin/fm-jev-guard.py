#!/usr/bin/env python3
"""fm-jev-guard.py - dynamic delegation guardrail for Firstmate using Jev System One.

Prevents Firstmate in w1 from falling into hands-on implementation and sysadmin
rabbit holes by intercepting commands, fast-passing legitimate supervisor tasks,
and querying Jev System One on ambiguous or mutating commands.

Usage:
  fm-jev-guard.py [--command <cmd>] [--check-only] [--json] [--debug]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

TS_BASE = os.environ.get("FM_JEV_TS_BASE", "https://api.typesafe.ai")
TS_MODEL = os.environ.get("FM_JEV_TS_MODEL", "jev-latest")
TS_TIMEOUT = float(os.environ.get("FM_JEV_GUARD_TIMEOUT", "3.0"))
CACHE_FILE = Path(os.environ.get("FM_JEV_GUARD_CACHE", "/dev/shm/.fm-jev-guard-cache.json"))

CRITERIA_ACTION = {
    "allow_supervisor": (
        "Legitimate supervisory action for Firstmate in workspace w1: draining queues, reading status files, "
        "managing beads/backlog, checking local git status of firstmate, routing or steering workers via fm-send/fm-route."
    ),
    "require_delegation": (
        "Hands-on implementation, debugging, or sysadmin work that must be delegated to a Second Mate or worker: "
        "SSHing to remote hosts (srv-covenant-app, gpu, svc), running package managers (apt, pip, npm), direct service "
        "control (systemctl restart/enable), editing application/project code, building or testing project code (npm test, pytest)."
    ),
}

CRITERIA_DOMAIN = {
    "supervisor": "Benign supervisor action: keep in w1.",
    "gpu_ops": "GPU host operations, Ollama, STT, whisper, models, CUDA, host configs on gpu.",
    "svc_ops": "Service operations, systemd, web server configs, Redis, reverse proxy, portal infrastructure on srv-covenant-app or svc.",
    "project_worker": "Application code changes, git commits/tags to projects, running tests, project builds.",
    "monitor_sre": "Stack monitoring, health checks, uptime alerts.",
    "firstmate_upstream": "Upstream firstmate pull requests and framework changes.",
}

# Approved supervisor prefix patterns for Tier 1 fast path
SUPERVISOR_TOOL_PREFIXES = (
    "bd ",
    "tasks-axi",
    "bin/fm-tasks-axi.sh",
    "bin/fm-send.sh",
    "bin/fm-route-",
    "bin/fm-wake-drain.sh",
    "bin/fm-brief.sh",
    "bin/fm-spawn.sh",
    "bin/fm-captain-hold.sh",
    "bin/fm-check-register.sh",
    "bin/fm-session",
    "bin/fm-jev-",
    "herdr",
)

# Supervisor lifecycle scripts (AGENTS.md sections 4/7/8): seat relaunch/interrupt,
# task PR merge and check, teardown, lease claim, current-state reads, fleet view.
# These are firstmate-owned supervision actions, never hands-on project work.
SUPERVISOR_LIFECYCLE_PREFIXES = (
    "bin/fm-control.sh",
    "bin/fm-teardown.sh",
    "bin/fm-pr-merge.sh",
    "bin/fm-pr-check.sh",
    "bin/fm-lease.sh",
    "bin/fm-crew-state.sh",
    "bin/fm-fleet-view.sh",
)

SAFE_READ_TOOLS = (
    "cat ",
    "head ",
    "tail ",
    "grep ",
    "rg ",
    "sed ",
    "awk ",
    "cut ",
    "tr ",
    "wc ",
    "ls ",
    "echo ",
    "printf ",
    "sleep ",
    "true",
    "false",
    "test ",
    "[ ",
)


def get_api_key(fm_root: Path | None = None) -> str | None:
    # 1. Environment
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key

    # 2. Try vault injection wrapper if available
    candidates = []
    if fm_root:
        candidates.append(fm_root / "bin" / "jev-typesafe-run.py")
    candidates.append(Path("/opt/ra/firstmate/bin/jev-typesafe-run.py"))

    for run_py in candidates:
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


def split_compound_commands(cmd: str) -> list[str]:
    """Split compound bash commands (;, &&, ||, newlines) while preserving quoted strings."""
    try:
        lexer = shlex.shlex(cmd, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True
        parts = []
        current = []
        for tok in lexer:
            if tok in (";", "&&", "||", "\n"):
                if current:
                    parts.append(" ".join(current))
                    current = []
            else:
                current.append(tok)
        if current:
            parts.append(" ".join(current))
        return parts if parts else [cmd]
    except Exception:
        # Fallback: simple line/semicolon split if lexer encounters syntax errors
        raw_parts = [p.strip() for p in re.split(r"[;\n]|&&|\|\|", cmd) if p.strip()]
        return raw_parts if raw_parts else [cmd]


def clean_subcommand(subcmd: str) -> str:
    """Strip leading variable assignments and comments from a subcommand."""
    s = subcmd.strip()
    # Strip leading shell comments
    s = re.sub(r"^#[^\n]*\n?", "", s).strip()
    # Strip leading env assignments like export FOO=bar or FOO=bar
    while True:
        m = re.match(r"^(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|\"[^\"]*\"|\S+)\s*", s)
        if m:
            s = s[m.end():].strip()
        else:
            break
    return s


def is_fast_pass_supervisor(subcmd: str) -> bool:
    """Check if an individual subcommand is unequivocally an allowed supervisor operation."""
    clean = clean_subcommand(subcmd)
    if not clean:
        return True

    # 1. Immediate disallow for remote ssh or systemd/package mutations
    if any(k in clean for k in ("ssh ", "ssh\t", "sudo ", "apt-get", "apt ", "systemctl", "journalctl", "docker ")):
        return False

    # 2. Approved supervisor tools (beads, tasks, routing, wake drain, etc.)
    #    plus the supervisor lifecycle scripts (control/merge/teardown/lease/state).
    if clean.startswith(SUPERVISOR_TOOL_PREFIXES) or clean.startswith(SUPERVISOR_LIFECYCLE_PREFIXES) or clean == "bd" or clean == "tasks-axi":
        return True

    # 3. Read-only git queries in Firstmate home
    if clean.startswith("git "):
        git_args = clean[4:].strip()
        if re.match(r"^(status|log|diff|rev-parse|show\s+origin/main|branch)\b", git_args):
            return True
        return False

    # 4. Read-only GitHub PR queries
    if clean.startswith("gh pr "):
        gh_args = clean[6:].strip()
        if re.match(r"^(view|status|list|checks)\b", gh_args):
            return True
        return False

    # 5. Safe file inspection / shell utilities
    if clean.startswith(SAFE_READ_TOOLS):
        # Disallow reading remote or dangerous paths if specified
        return True

    return False


def is_whitelisted_command(cmd: str) -> bool:
    """Tier 1: Check if all components of the command belong to the supervisor whitelist."""
    subcmds = split_compound_commands(cmd)
    if not subcmds:
        return True
    return all(is_fast_pass_supervisor(part) for part in subcmds)


def load_cache() -> dict[str, dict]:
    try:
        if CACHE_FILE.exists():
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        pass
    return {}


def save_cache(cache: dict[str, dict]) -> None:
    try:
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        # Keep cache bounded to 500 entries
        if len(cache) > 500:
            keys = list(cache.keys())[-300:]
            cache = {k: cache[k] for k in keys}
        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump(cache, f)
    except Exception:
        pass


def get_cached_decision(cmd: str) -> dict | None:
    cache = load_cache()
    cmd_hash = hashlib.sha256(cmd.strip().encode("utf-8")).hexdigest()
    return cache.get(cmd_hash)


def cache_decision(cmd: str, decision_data: dict) -> None:
    cache = load_cache()
    cmd_hash = hashlib.sha256(cmd.strip().encode("utf-8")).hexdigest()
    cache[cmd_hash] = decision_data
    save_cache(cache)


def get_suggested_dispatch(cmd: str, domain: str) -> str:
    if domain == "gpu_ops":
        return "bin/fm-send.sh gpu-ops '<task instructions>'"
    elif domain == "svc_ops":
        return "bin/fm-send.sh svc-ops '<task instructions>'"
    elif domain == "monitor_sre":
        return "bin/fm-send.sh monitor-sre '<task instructions>'"
    elif domain == "firstmate_upstream":
        return "bin/fm-send.sh 2ndmate-firstmate-upstream '<task instructions>'"
    else:
        return "bin/fm-route-dispatch.sh --task '<task instructions>'"


def query_jev_guard(cmd: str, api_key: str) -> dict:
    clean_cmd = " ".join(cmd.split())[:800]
    payload = {
        "model": TS_MODEL,
        "state": {
            "role": "firstmate_primary_supervisor_w1",
            "command": clean_cmd,
            "policy": (
                "Firstmate is the executive primary supervisor in workspace w1. "
                "Firstmate's duty is delegating tasks, steering Second Mates, managing beads, "
                "and triage. Direct hands-on sysadmin (SSHing to remote hosts like srv-covenant-app "
                "or gpu, service restarts, editing systemd configs, apt/pip installs) and application "
                "code changes/testing must be delegated to Second Mates."
            ),
        },
        "questions": {
            "action": {
                "type": "choice",
                "instructions": "Should Firstmate be allowed to execute this command in w1, or does it violate supervisor boundaries and require delegation to a Second Mate?",
                "criteria": CRITERIA_ACTION,
            },
            "violation_noul": {
                "type": "noul",
                "instructions": "Probability (0.0 to 1.0) that this command violates supervisor boundaries in w1 and is hands-on work that should be delegated.",
            },
            "target_domain": {
                "type": "choice",
                "instructions": "If this command requires delegation, which domain / Second Mate seat should own it?",
                "criteria": CRITERIA_DOMAIN,
            },
        },
    }

    req = urllib.request.Request(
        f"{TS_BASE}/v1/systemone",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=TS_TIMEOUT) as resp:
        data = json.loads(resp.read().decode("utf-8"))

    answers = data.get("answers", {})
    action = answers.get("action", {}).get("choice", "allow_supervisor")
    violation_noul = float(answers.get("violation_noul", {}).get("noul", 0.0))
    target_domain = answers.get("target_domain", {}).get("choice", "supervisor")

    is_deny = (action == "require_delegation") or (violation_noul >= 0.70)
    suggested = get_suggested_dispatch(cmd, target_domain)

    if is_deny:
        reason = (
            f"Command violates supervisor boundary in w1 ({target_domain}). "
            f"Hands-on execution must be delegated to Second Mates."
        )
        return {
            "decision": "deny",
            "code": "require_delegation",
            "reason": reason,
            "target_domain": target_domain,
            "violation_noul": violation_noul,
            "suggested_command": suggested,
        }
    else:
        return {
            "decision": "allow",
            "code": "supervisor_approved",
            "reason": "Command within supervisor boundary",
            "target_domain": target_domain,
            "violation_noul": violation_noul,
            "suggested_command": "",
        }


def stamp_guard_telemetry(cmd: str, result: dict, fm_root: Path | None = None) -> None:
    try:
        root = fm_root or Path("/opt/ra/firstmate")
        state_dir = root / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        telemetry_file = state_dir / ".jev-guard-telemetry"
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        decision = result.get("decision", "allow")
        tier = result.get("tier", 1)
        domain = result.get("target_domain", "-")
        code = result.get("code", "-")
        clean_cmd = " ".join(cmd.split())[:160]
        line = f"{ts}\t{decision}\ttier{tier}\t{code}\t{domain}\t{clean_cmd}\n"
        with open(telemetry_file, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def _evaluate_command_inner(cmd: str, fm_root: Path | None = None) -> dict:
    cmd_clean = cmd.strip()
    if not cmd_clean:
        return {"decision": "allow", "code": "empty_cmd", "reason": "empty command"}

    # Tier 1: Fast-path whitelist
    if is_whitelisted_command(cmd_clean):
        return {
            "decision": "allow",
            "code": "fast_path_whitelist",
            "reason": "Approved supervisor tool or benign inspection",
            "tier": 1,
        }

    # Tier 2: Cache check
    cached = get_cached_decision(cmd_clean)
    if cached:
        cached["tier"] = 2
        return cached

    # Tier 3: Jev System One evaluation
    api_key = get_api_key(fm_root)
    if not api_key:
        # Fail-open if API key is not configured
        return {
            "decision": "allow",
            "code": "fail_open_no_key",
            "reason": "TYPESAFE_API_KEY unavailable; failing open",
            "tier": 3,
        }

    try:
        res = query_jev_guard(cmd_clean, api_key)
        res["tier"] = 3
        # Cache allowed or benign results
        if res.get("decision") == "allow":
            cache_decision(cmd_clean, res)
        return res
    except Exception as exc:
        # Fail-open on timeout or network errors
        return {
            "decision": "allow",
            "code": "fail_open_error",
            "reason": f"Jev query error ({exc}); failing open",
            "tier": 3,
        }


def evaluate_command(cmd: str, fm_root: Path | None = None) -> dict:
    res = _evaluate_command_inner(cmd, fm_root)
    stamp_guard_telemetry(cmd, res, fm_root)
    return res


def main() -> int:
    parser = argparse.ArgumentParser(description="Jev dynamic delegation guardrail for Firstmate")
    parser.add_argument("--command", "-c", help="Command string to evaluate")
    parser.add_argument("--check-only", action="store_true", help="Print tab-separated decision and exit")
    parser.add_argument("--json", action="store_true", help="Output full decision as JSON")
    parser.add_argument("--debug", action="store_true", help="Print debug information to stderr")
    args = parser.parse_args()

    cmd = args.command
    if not cmd:
        # Try stdin
        if not sys.stdin.isatty():
            payload_str = sys.stdin.read().strip()
            if payload_str:
                try:
                    p = json.loads(payload_str)
                    cmd = (
                        p.get("toolInput", {}).get("command")
                        or p.get("tool_input", {}).get("command")
                        or payload_str
                    )
                except Exception:
                    cmd = payload_str

    if not cmd:
        # Nothing to evaluate -> allow
        return 0

    script_dir = Path(__file__).resolve().parent
    fm_root = Path(os.environ.get("FM_ROOT_OVERRIDE", script_dir.parent))

    result = evaluate_command(cmd, fm_root)

    if args.json:
        print(json.dumps(result, indent=2))
    elif args.check_only:
        decision = result.get("decision", "allow")
        code = result.get("code", "")
        reason = result.get("reason", "")
        domain = result.get("target_domain", "")
        suggested = result.get("suggested_command", "")
        print(f"{decision}\t{code}\t{reason}\t{domain}\t{suggested}")
    else:
        # Default behavior: exit code 0 for allow, 2 for deny
        if result.get("decision") == "deny":
            code = result.get("code", "require_delegation")
            reason = result.get("reason", "")
            suggested = result.get("suggested_command", "")
            sys.stderr.write(f"[{code}] {reason}\n")
            if suggested:
                sys.stderr.write(f"-> Suggested: {suggested}\n")
            return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
