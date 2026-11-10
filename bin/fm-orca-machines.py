#!/usr/bin/env python3
"""Select an Orca machine without changing its runtime or repositories.

Usage: fm-orca-machines.py select CONFIG PROJECT [BASE-REF]
CONFIG follows the Orca machines schema in docs/configuration.md.
Output the selected row as JSON. Probes use bounded, noninteractive SSH and
read-only Python/git commands; this helper never provisions a machine.
"""

import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


ATOM = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
HOST = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@-]*\Z")
PROBE = """
import json, os, shutil, subprocess, sys
p, ref = sys.argv[2:]
r = subprocess.run(['git','-C',p,'rev-parse','--verify',ref+'^{commit}'],
                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
orca = shutil.which('orca') or '/Applications/Orca.app/Contents/Resources/bin/orca'
runtime = json.loads(subprocess.check_output([orca,'status','--json'], timeout=5))['result']['runtime']
print(json.dumps(dict(load=os.getloadavg()[0], cores=os.cpu_count(),
                     runtime_id=runtime['runtimeId'],
                     head=r.stdout.strip() if r.returncode == 0 else None)))
"""


def read_config(path):
    path = Path(path)
    if not path.exists():
        if path.is_symlink():
            raise ValueError("broken orca-machines configuration link")
        return []
    rows = json.loads(path.read_text())
    if not isinstance(rows, list):
        raise ValueError("orca-machines must be a JSON array")
    seen = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) - {
            "environment", "ssh", "max_load_per_core"
        }:
            raise ValueError("invalid orca-machines row or unknown field")
        env = row.get("environment")
        ceiling = row.get("max_load_per_core")
        if not isinstance(env, str) or not ATOM.fullmatch(env) or env in seen:
            raise ValueError("invalid or duplicate Orca environment")
        seen.add(env)
        if (isinstance(ceiling, bool) or not isinstance(ceiling, (int, float))
                or not math.isfinite(ceiling) or ceiling <= 0):
            raise ValueError("max_load_per_core must be finite and positive")
        if env == "local":
            if "ssh" in row:
                raise ValueError("local Orca row must not declare ssh")
        elif not isinstance(row.get("ssh"), str) or not HOST.fullmatch(row["ssh"]):
            raise ValueError("remote Orca row requires a safe SSH alias")
    return rows


def probe(row, project, ref):
    args = ["python3", "-c", PROBE, "--fm-orca-load-probe", project, ref]
    if row["environment"] != "local":
        args = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                row["ssh"], shlex.join(args)]
    result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True,
                            text=True, timeout=10, check=True)
    data = json.loads(result.stdout)
    cores, load = data.get("cores"), data.get("load")
    if (isinstance(cores, bool) or not isinstance(cores, int) or cores <= 0
            or isinstance(load, bool) or not isinstance(load, (int, float))
            or not math.isfinite(load) or load < 0):
        raise ValueError("invalid load probe")
    return data


def select(config, project, ref="HEAD"):
    rows = read_config(config)
    if not rows:
        return {"environment": "local"}
    expected = subprocess.run(
        ["git", "-C", project, "rev-parse", "--verify", ref + "^{commit}"],
        capture_output=True, text=True, check=True, timeout=10).stdout.strip()
    for row in rows:
        try:
            data = probe(row, project, ref)
            if data["head"] != expected:
                reason = "project absent or base commit differs"
            elif data["load"] / data["cores"] >= row["max_load_per_core"]:
                reason = "load ceiling reached"
            else:
                if row["environment"] == "local":
                    return row
                env = os.environ.copy()
                env.pop("ORCA_PAIRING_CODE", None)
                env.pop("ORCA_ENVIRONMENT", None)
                result = subprocess.run(["orca", "status", "--environment", row["environment"], "--json"],
                                        capture_output=True, text=True, timeout=10, check=True, env=env)
                runtime = json.loads(result.stdout)["result"]["runtime"]
                identity = runtime.get("runtimeId")
                if (not isinstance(identity, str) or not ATOM.fullmatch(identity)
                        or identity != data.get("runtime_id")
                        or runtime.get("reachable") is not True or runtime.get("state") != "ready"):
                    reason = "saved environment and SSH host do not identify the same ready runtime"
                else:
                    return {**row, "runtime_id": runtime["runtimeId"]}
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            reason = "probe unavailable"
        print(f"orca: skipping {row['environment']}: {reason}", file=sys.stderr)
    return {"environment": "local"}


if __name__ == "__main__":
    try:
        if len(sys.argv) not in (4, 5) or sys.argv[1] != "select":
            raise ValueError(__doc__)
        print(json.dumps(select(*sys.argv[2:])))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"error: Orca machine selection refused: {exc}", file=sys.stderr)
        sys.exit(1)
