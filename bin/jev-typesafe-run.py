#!/usr/bin/env python3
"""Root-only: run a command with TYPESAFE_API_KEY from Arcs Live 'Jev API Key'. No dest file."""
from __future__ import annotations

import os
import pwd
import subprocess
import sys
import tempfile
from pathlib import Path

TOKEN_FILE = Path("/etc/arcs/op-token")
ITEM = "TypeSafe Jev API Key"
VAULT = "Arcs Live"
FIELD = "credential"
CONSUMER = "jon"


def die(msg: str, code: int = 1) -> None:
    print(f"jev_typesafe_run=FAIL {msg}", file=sys.stderr)
    raise SystemExit(code)


def main() -> None:
    if os.geteuid() != 0:
        die("must run as root (sudo -n python3 ...)")
    args = sys.argv[1:]
    if args[:1] == ["--"]:
        args = args[1:]
    if not args:
        die("usage: sudo -n python3 jev-typesafe-run.py -- <command> [args...]")
    token = TOKEN_FILE.read_text().strip()
    if not token:
        die("operator token empty")
    config_home = tempfile.mkdtemp(prefix="agent-vault-op-")
    try:
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("OP_") and k not in ("HOME", "XDG_CONFIG_HOME", "AGENT_VAULT_OPERATOR_TOKEN")
        }
        env["OP_SERVICE_ACCOUNT_TOKEN"] = token
        env["OP_CACHE"] = "false"
        env["HOME"] = config_home
        proc = subprocess.run(
            [
                "/usr/local/bin/op",
                "item",
                "get",
                ITEM,
                "--vault",
                VAULT,
                "--fields",
                f"label={FIELD}",
                "--reveal",
            ],
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
    finally:
        subprocess.run(["rm", "-rf", config_home], check=False)
    if proc.returncode != 0:
        die("op item get failed")
    key = proc.stdout.strip()
    proc = None
    if not key or "\n" in key or "\r" in key:
        die("credential empty or multiline")
    consumer = pwd.getpwnam(CONSUMER)
    run_env = os.environ.copy()
    run_env.pop("OP_SERVICE_ACCOUNT_TOKEN", None)
    run_env.pop("AGENT_VAULT_OPERATOR_TOKEN", None)
    run_env["TYPESAFE_API_KEY"] = key
    key = ""
    os.initgroups(consumer.pw_name, consumer.pw_gid)
    os.setgid(consumer.pw_gid)
    os.setuid(consumer.pw_uid)
    os.execvpe(args[0], args, run_env)


if __name__ == "__main__":
    main()
