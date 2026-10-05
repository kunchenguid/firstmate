#!/usr/bin/env python3
"""Opt-in knowledge-check protocol for fm-merge-local.sh landings.

Usage: python3 -I fm-knowledge-landing.py <config> <home> <project> <base-oid> <head-oid> <task-id>
<home> is the home that owns the task's state, whatever FM_HOME the landing
runs under. The caller runs this only when its config/knowledge-landing (or
FM_CONFIG_OVERRIDE's copy) exists,
pins both commits, checks ancestry and cleanliness, and merges only head-oid
after success. This helper never merges or grants merge authority.

The config holds one key=value per line; blank and # lines are ignored:
  checker=<path>    exactly one; the checker's path inside the project repository
  approvals=<dir>   exactly one; approval records, one file per task ID
  ok=<prefix>       one or more; final-line prefixes the checker prints on a pass
  project=<dir>     optional, repeatable; repositories that always need the check
Relative approvals/project paths resolve against <home>. A malformed config
refuses. The check applies when the captured base carries the checker, or when
the project shares a Git common directory with a configured project directory
that is itself a work-tree top level. A non-Git or nested configured directory
matches nothing. Otherwise this helper exits 0 and the landing is unchanged.

When it applies, the current clean checkout's checker runs as
<checker> <base-oid> <head-oid> --root <project>, with a 90-second deadline.
Both interpreters use isolated mode so inherited Python startup customization
cannot replace the verdict. Failed verdicts retain checker output for diagnosis.

A complete verdict's first line is "<name>: base <oid> head <oid> merge-base
<oid>[; ...]" naming the requested base, head and merge-base (base, because
this entrypoint only fast-forwards). Exit 0 plus a final line starting with a
configured ok prefix and no FAIL/ERROR lines passes. Exit 2 plus FAIL lines and
a final REFUSED line requires a regular, non-symlink <approvals>/<task-id>
whose first line is exactly head-oid, written only after explicit approval of
that commit. A missing checker, timeout, unexpected exit, ERROR, incomplete or
mismatched verdict always refuses, even with approval.
The checker owns content policy; this helper owns only this protocol.
No shell command text or harness hook participates in the landing decision.
Exit 0 permits the caller to continue; exit 1 refuses.
"""

import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys


OID = r"(?:[0-9a-f]{40}|[0-9a-f]{64})"
HEADER = re.compile(
    r"[^:]+: base (" + OID + r") head (" + OID + r") merge-base (" + OID + r")(?:;.*)?"
)
KEYS = ("checker", "approvals", "ok", "project")


def settings(config):
    values = {key: [] for key in KEYS}
    with open(config, encoding="utf-8") as lines:
        for number, line in enumerate(lines, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            key, separator, value = line.partition("=")
            if not separator or key not in values or not value:
                raise ValueError("%s:%d: expected checker=, approvals=, ok= or project=" % (config, number))
            values[key].append(value)
    checker = PurePosixPath(values["checker"][0]) if len(values["checker"]) == 1 else None
    if (checker is None or checker.is_absolute() or ".." in checker.parts
            or len(values["approvals"]) != 1 or not values["ok"]):
        raise ValueError(config + " needs one relative checker=, one approvals= and at least one ok=")
    return values


def git(directory, *args):
    return subprocess.run(["git", "-C", directory] + list(args),
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def common_directory(directory, top_level):
    result = git(directory, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir")
    lines = result.stdout.decode("utf-8", "surrogateescape").splitlines()
    if result.returncode != 0 or len(lines) != 2:
        return None
    if top_level and Path(lines[0]).resolve() != Path(directory).resolve():
        return None
    return Path(lines[1]).resolve()


def applies(values, home, project, base):
    if git(project, "cat-file", "-e", base + ":" + values["checker"][0]).returncode == 0:
        return True
    own = common_directory(project, False)
    if own is None:
        raise ValueError("cannot resolve the Git common directory of " + project)
    return any(common_directory(str(Path(home, configured)), True) == own
               for configured in values["project"])


def approved(path, head):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            return (stat.S_ISREG(os.fstat(fd).st_mode)
                    and os.read(fd, 1024).split(b"\n", 1)[0] == head.encode("ascii"))
        finally:
            os.close(fd)
    except OSError:
        return False


def main(args):
    if len(args) != 6 or any(re.fullmatch(OID, oid) is None for oid in args[3:5]):
        raise ValueError("expected config, home, project, full base/head commit IDs and task ID")
    config, home, project, base, head, task = args
    values = settings(config)
    if not applies(values, home, project, base):
        return 0
    approval = str(Path(home, values["approvals"][0], task))
    gate = Path(project, values["checker"][0])
    if not gate.is_file() or gate.is_symlink():
        raise ValueError("knowledge checker is missing or is not a regular file")
    result = subprocess.run(
        [sys.executable, "-I", "-B", str(gate), base, head, "--root", project],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90,
    )
    output = result.stdout.decode("utf-8", "strict")
    lines = output.splitlines()
    header = HEADER.fullmatch(lines[0]) if lines else None
    if (header is None or header.groups() != (base, head, base)
            or any(line.startswith("ERROR") for line in lines)):
        sys.stderr.write(output + result.stderr.decode("utf-8", "replace"))
        raise ValueError("knowledge checker returned an incomplete, failed or mismatched verdict")
    failures = [line for line in lines if line.startswith("FAIL ")]
    if result.returncode == 0 and lines[-1].startswith(tuple(values["ok"])) and not failures:
        print(output, end="")
        return 0
    if result.returncode == 2 and failures and lines[-1].startswith("REFUSED "):
        print(output, end="")
        if approved(approval, head):
            print("knowledge landing: explicit approval matches " + head)
            return 0
        raise ValueError("knowledge landing requires explicit approval of " + head + " in " + approval)
    sys.stderr.write(output + result.stderr.decode("utf-8", "replace"))
    raise ValueError("knowledge checker did not return a complete pass or policy refusal")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("error: local merge refused: " + str(error), file=sys.stderr)
        sys.exit(1)
