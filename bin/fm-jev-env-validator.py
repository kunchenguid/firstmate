#!/usr/bin/env python3
"""
fm-jev-env-validator.py - Jev Cross-Seat Environment Variable & Credential Drift Validator (Pattern 28)

Audits environment variable contracts and credential presence across fleet worker contexts,
verifying presence and readability while strictly ensuring zero secret values, tokens,
or passwords are printed, logged, or emitted in telemetry.

Invariants:
- Zero Secret Egress: NEVER prints or exposes values; reports only "present", "absent", or "unreadable".
- Non-Destructive: Read-only inspection of declared variables and paths.
- Fail-open: Emits structured JSON telemetry (--json).
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

STANDARD_ENV_CONTRACTS = [
    "FM_HOME",
    "PATH",
    "HOME",
    "USER",
    "SHELL",
]

CREDENTIAL_PATHS_TO_CHECK = [
    "/etc/credstore.encrypted",
    "/etc/restic/covenant-password",
    "/home/jon/.config/gh/hosts.yml",
]


def audit_env_vars(extra_vars: Optional[List[str]] = None) -> Dict[str, Any]:
    vars_to_check = list(STANDARD_ENV_CONTRACTS)
    if extra_vars:
        vars_to_check.extend(extra_vars)

    results = {}
    for var in vars_to_check:
        val = os.environ.get(var)
        if val is None:
            status = "missing"
        elif len(val.strip()) == 0:
            status = "empty"
        else:
            status = "present"
        results[var] = {
            "status": status,
            "length": len(val) if val else 0,
        }
    return results


def audit_credential_paths(extra_paths: Optional[List[str]] = None) -> Dict[str, Any]:
    paths_to_check = [Path(p) for p in CREDENTIAL_PATHS_TO_CHECK]
    if extra_paths:
        paths_to_check.extend([Path(p) for p in extra_paths])

    results = {}
    for p in paths_to_check:
        path_str = str(p)
        if not p.exists():
            status = "missing"
        elif not os.access(p, os.R_OK):
            status = "unreadable"
        else:
            status = "available"
        results[path_str] = {
            "status": status,
            "is_dir": p.is_dir() if p.exists() else False,
            "is_file": p.is_file() if p.exists() else False,
        }
    return results


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Cross-Seat Environment Variable & Credential Drift Validator (Pattern 28)"
    )
    parser.add_argument(
        "--vars",
        help="Comma-separated list of additional environment variable names to audit",
    )
    parser.add_argument(
        "--paths",
        help="Comma-separated list of additional credential paths to audit",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry",
    )

    args = parser.parse_args()

    extra_vars = [v.strip() for v in args.vars.split(",")] if args.vars else None
    extra_paths = [p.strip() for p in args.paths.split(",")] if args.paths else None

    env_results = audit_env_vars(extra_vars)
    path_results = audit_credential_paths(extra_paths)

    missing_env_count = sum(1 for v in env_results.values() if v["status"] == "missing")
    empty_env_count = sum(1 for v in env_results.values() if v["status"] == "empty")
    missing_path_count = sum(1 for p in path_results.values() if p["status"] == "missing")

    telemetry = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "summary": {
            "total_vars_audited": len(env_results),
            "missing_vars": missing_env_count,
            "total_paths_audited": len(path_results),
            "missing_paths": missing_path_count,
            "empty_vars": empty_env_count,
            "healthy": (missing_env_count == 0 and empty_env_count == 0),
        },
        "environment": env_results,
        "credentials": path_results,
    }

    if args.json:
        print(json.dumps(telemetry, indent=2))
    else:
        print("Jev Environment & Credential Drift Validator (Pattern 28):")
        print(f"  • Environment Variables Audited: {len(env_results)} ({missing_env_count} missing)")
        for var, d in env_results.items():
            flag = "✓" if d["status"] == "present" else "✗"
            print(f"    {flag} {var}: {d['status']}")
        print(f"  • Credential Targets Audited: {len(path_results)} ({missing_path_count} missing)")
        for path, d in path_results.items():
            flag = "✓" if d["status"] == "available" else "✗"
            print(f"    {flag} {path}: {d['status']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
