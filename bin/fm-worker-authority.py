#!/usr/bin/env python3
"""Issue exact release receipts from ordinary local Firstmate authorities."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


AUTHORITY_SCHEMA = "fm.worker-authority/v1"
RELEASE_SCHEMA = "fm.worker-release/v2"
REQUIRED_HEADINGS = (
    "## Summary", "## What changed", "## Verification", "## Visual evidence",
    "## Artifacts", "## Follow-ups",
)


class AuthorityError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def git(path, *args):
    result = subprocess.run(
        ["git", "-C", str(path)] + list(args), text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise AuthorityError("git authority failed: {}".format(result.stderr.strip()))
    return result.stdout.strip()


def meta(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values.setdefault(key, []).append(value)
    return values


def exactly(values, key):
    entries = values.get(key, [])
    if len(entries) != 1 or not entries[0]:
        raise AuthorityError("task metadata {} identity is not exact".format(key))
    return entries[0]


def receipt(name, task, generation, assignment, evidence):
    value = {
        "schema": AUTHORITY_SCHEMA,
        "authority": name,
        "task": task,
        "task_generation": generation,
        "assignment_generation": assignment,
        "verdict": "proved",
        "evidence_digest": hashlib.sha256(evidence).hexdigest(),
    }
    value["receipt_digest"] = digest(value)
    return value


def endpoint_evidence(home, task, values):
    backend = values.get("backend", ["tmux"])[0]
    target = exactly(values, "window")
    expected = "fm-{}".format(task)
    helper = home / "bin" / "fm-backend.sh"
    script = '. "$1"; fm_backend_target_state "$2" "$3" "$4" "${5:-}"'
    result = subprocess.run(
        ["bash", "-c", script, "_", str(helper), backend, target, expected,
         values.get("tmux_session_target", [""])[0]],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={**os.environ, "FM_HOME": str(home), "FM_ROOT": str(home)},
    )
    if result.returncode != 0 or result.stdout.strip() != "absent":
        raise AuthorityError("endpoint authority did not prove the exact task endpoint absent")
    return "{}\0{}\0{}\0absent".format(backend, target, expected).encode()


def report_evidence(home, task):
    path = home / "data" / task / "completion.md"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise AuthorityError("completion report authority is absent, redirected, or oversized")
    content = path.read_bytes()
    text = content.decode("utf-8")
    positions = [text.find(heading) for heading in REQUIRED_HEADINGS]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        raise AuthorityError("completion report authority lacks the exact ordered contract headings")
    return content


def worktree_evidence(task, values):
    worktree = Path(exactly(values, "worktree")).resolve()
    if worktree.is_symlink() or not worktree.is_dir() or Path(git(worktree, "rev-parse", "--show-toplevel")).resolve() != worktree:
        raise AuthorityError("worktree authority is not the exact repository root")
    if git(worktree, "status", "--porcelain=v1", "--untracked-files=all"):
        raise AuthorityError("writable worktree authority is dirty")
    common = Path(git(worktree, "rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = (worktree / common).resolve()
    return "{}\0{}\0{}".format(worktree, common.resolve(), git(worktree, "rev-parse", "HEAD")).encode(), worktree


def landing_evidence(worktree, repository_generation):
    # Only the canonical origin remote proves landing; a scratch or fork
    # remote-tracking ref must not count, and an unpushed local default
    # branch is not landed work. The landed head must also descend from the
    # assignment's exact starting repository generation, so a receipt can
    # never be minted from an unrelated worktree lineage.
    head = git(worktree, "rev-parse", "HEAD")
    lineage = subprocess.run(
        ["git", "-C", str(worktree), "merge-base", "--is-ancestor", repository_generation, head]
    )
    if lineage.returncode != 0:
        raise AuthorityError("landing authority head does not descend from the assignment repository generation")
    git(
        worktree, "fetch", "--quiet", "--no-tags", "--prune", "origin",
        "+refs/heads/*:refs/remotes/origin/*",
    )
    refs = git(worktree, "for-each-ref", "--format=%(refname)", "refs/remotes/origin").splitlines()
    for ref in refs:
        if ref == "refs/remotes/origin/HEAD":
            continue
        result = subprocess.run(["git", "-C", str(worktree), "merge-base", "--is-ancestor", head, ref])
        if result.returncode == 0:
            return "{}\0{}\0{}".format(head, ref, repository_generation).encode()
    raise AuthorityError("landing authority did not prove committed work reachable from the origin remote")


def account_evidence(values, task, home):
    account_home = exactly(values, "account_home")
    if not Path(account_home).resolve().is_dir():
        raise AuthorityError("account authority directory is unavailable")
    account_task = values.get("account_task", [task])[0]
    if account_task != task:
        raise AuthorityError("account authority task identity differs")
    helper = home / "bin" / "fm-account-directory.sh"
    if not helper.is_file():
        raise AuthorityError("ordinary account authority helper is unavailable")
    vendor = "claude" if "claude" in Path(account_home).parts else "codex" if "codex" in Path(account_home).parts else ""
    if not vendor:
        raise AuthorityError("ordinary account authority vendor is ambiguous")
    script = '. "$1"; root=$(resolve_account_root); vendor_dir=$(real_dir "$root/$2"); valid_account_home "$vendor_dir" "$3"; real_dir "$3"'
    result = subprocess.run(
        ["bash", "-c", script, "_", str(home / "bin" / "fm-account-directory.sh"), vendor, account_home],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={**os.environ, "FM_HOME": str(home), "FM_ROOT": str(home)},
    )
    if result.returncode != 0:
        raise AuthorityError("ordinary account authority did not prove the exact task/account home")
    account_real = result.stdout.decode().strip()
    if Path(account_real).resolve() != Path(account_home).resolve():
        raise AuthorityError("ordinary account authority canonical home differs")
    return "{}\0{}\0ordinary-account-owner".format(Path(account_home).resolve(), account_task).encode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument("--task-generation", required=True)
    parser.add_argument("--assignment-generation", required=True)
    parser.add_argument("--worker-state", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}", args.task):
        raise AuthorityError("task identity is malformed")
    home = Path(args.home).resolve()
    metadata = home / "state" / (args.task + ".meta")
    if metadata.is_symlink() or not metadata.is_file():
        raise AuthorityError("ordinary task metadata authority is absent")
    values = meta(metadata)
    generation = exactly(values, "generation_id")
    if generation != args.task_generation:
        raise AuthorityError("ordinary task generation differs")
    worker = json.loads(Path(args.worker_state).read_text(encoding="utf-8"))
    if worker["assignment_generation"] != args.assignment_generation:
        raise AuthorityError("worker assignment generation differs")
    worktree_info, worktree = worktree_evidence(args.task, values)
    authorities = {
        "endpoint": receipt("endpoint", args.task, generation, args.assignment_generation, endpoint_evidence(home, args.task, values)),
        "report": receipt("report", args.task, generation, args.assignment_generation, report_evidence(home, args.task)),
        "landing": receipt(
            "landing", args.task, generation, args.assignment_generation,
            landing_evidence(worktree, worker["bindings"]["repository_generation"]),
        ),
        "account": receipt("account", args.task, generation, args.assignment_generation, account_evidence(values, args.task, home)),
        "worktree": receipt("worktree", args.task, generation, args.assignment_generation, worktree_info),
    }
    proof = {
        "schema": RELEASE_SCHEMA,
        "home_binding": worker["bindings"]["home_binding"],
        "task": args.task,
        "task_generation": generation,
        "assignment_generation": args.assignment_generation,
        "account_binding": worker["bindings"]["account_binding"],
        "worktree_binding": worker["bindings"]["worktree_binding"],
        "repository_binding": worker["bindings"]["repository_binding"],
        "repository_generation": worker["bindings"]["repository_generation"],
        "cloud_instance_id": worker["cloud_instance_id"],
        "resources": worker["resources"],
        "authorities": authorities,
    }
    proof["proof_digest"] = digest(proof)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    output.write_text(json.dumps(proof, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    os.chmod(output, 0o600)


if __name__ == "__main__":
    try:
        main()
    except (AuthorityError, OSError, KeyError, json.JSONDecodeError) as exc:
        print("WORKER AUTHORITY REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
