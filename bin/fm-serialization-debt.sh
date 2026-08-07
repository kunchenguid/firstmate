#!/usr/bin/env bash
# fm-serialization-debt.sh - bounded, read-only same-shift serialization debt probe.
#
# Usage:
#   fm-serialization-debt.sh --project <path> [--base <ref>]
#                            [--shift-seconds <n>] [--now <epoch>]
#
# Prints nothing and exits 0 when evidence is available and no debt exists.
# Prints one explained SERIALIZATION-DEBT line per debt item and exits 1 when
# action is required. Missing, malformed, truncated, or timed-out git or task
# evidence prints SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE and also exits 1.
# The probe reads refs, the project's HEAD reflog, and the project's existing
# op-direction task records; it never updates a branch, task, or checkout.
# Debt begins strictly after the age boundary.
#
# Checkout-state debt: when the project checkout is not on the configured base
# branch - any other local branch, or a detached HEAD - the probe dates the
# checkout transition from the most recent `checkout:` entry in the bounded
# HEAD reflog window (the newest 200 entries) and reports debt strictly beyond
# the shift threshold. The target commit's age is never used, so switching to
# an old branch cannot false-positive. A transition older than the reflog
# window, or missing, malformed, or unreadable reflog evidence, fails closed
# as SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE.
set -u

exec python3 - "$@" <<'PY'
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys

parser = argparse.ArgumentParser(add_help=True)
parser.add_argument("--project", default=os.environ.get("FM_SERIALIZATION_PROJECT", "/home/holu/decision-os"))
parser.add_argument("--base", default=os.environ.get("FM_SERIALIZATION_BASE_REF", "main"))
parser.add_argument("--shift-seconds", type=int, default=int(os.environ.get("FM_SERIALIZATION_SHIFT_SECONDS", "28800")))
parser.add_argument("--now", type=int, default=int(os.environ.get("FM_SERIALIZATION_NOW_EPOCH", str(int(dt.datetime.now(dt.timezone.utc).timestamp())))))
args = parser.parse_args()

if args.shift_seconds < 0 or args.now < 0:
    print("SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE: source=arguments reason=negative-age-input")
    raise SystemExit(1)

timeout_seconds = 5
output_limit = 1_000_000
reflog_window = 200
min_plausible_epoch = 1104537600  # 2005-01-01: a real reflog date, not a selector index


class EvidenceUnavailable(Exception):
    pass


def run(source, command):
    try:
        result = subprocess.run(
            command,
            cwd=args.project,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_seconds,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EvidenceUnavailable(f"{source}-command-unavailable:{type(error).__name__}") from error
    if len(result.stdout) > output_limit or len(result.stderr) > output_limit:
        raise EvidenceUnavailable(f"{source}-output-exceeded-bound")
    if result.returncode != 0:
        raise EvidenceUnavailable(f"{source}-command-exit-{result.returncode}")
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise EvidenceUnavailable(f"{source}-output-not-utf8") from error


def checkout_transition_age(args, expected_branch):
    reflog = run(
        "git-checkout-reflog",
        ["git", "reflog", "show", "-n", str(reflog_window), "--date=unix", "HEAD"],
    )
    record = re.compile(r"^[0-9a-f]+ HEAD@\{(\d+)\}: (.*)$")
    for line in reflog.splitlines():
        match = record.match(line)
        if not match:
            raise EvidenceUnavailable("git-checkout-reflog-record-malformed")
        epoch = int(match.group(1))
        subject = match.group(2)
        if epoch < min_plausible_epoch:
            raise EvidenceUnavailable("git-checkout-reflog-record-malformed")
        if not subject.startswith("checkout:"):
            continue
        if expected_branch is not None and subject.split()[-1] != expected_branch:
            raise EvidenceUnavailable("git-checkout-reflog-state-mismatch")
        return epoch
    raise EvidenceUnavailable("git-checkout-reflog-truncated")


def current_checkout(args):
    expected_short = args.base[11:] if args.base.startswith("refs/heads/") else args.base
    try:
        symbolic = subprocess.run(
            ["git", "symbolic-ref", "-q", "--short", "HEAD"],
            cwd=args.project,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_seconds,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EvidenceUnavailable(
            f"git-checkout-state-command-unavailable:{type(error).__name__}"
        ) from error
    if len(symbolic.stdout) > output_limit or len(symbolic.stderr) > output_limit:
        raise EvidenceUnavailable("git-checkout-state-output-exceeded-bound")
    if symbolic.returncode not in (0, 1):
        raise EvidenceUnavailable(f"git-checkout-state-command-exit-{symbolic.returncode}")
    if symbolic.returncode == 0:
        try:
            branch = symbolic.stdout.decode("utf-8").strip()
        except UnicodeDecodeError as error:
            raise EvidenceUnavailable("git-checkout-state-output-not-utf8") from error
        if not branch:
            raise EvidenceUnavailable("git-checkout-state-record-malformed")
        if branch == expected_short:
            return None, None
        return branch, checkout_transition_age(args, expected_branch=branch)
    head = run("git-checkout-head", ["git", "rev-parse", "--short", "HEAD"]).strip()
    if not head:
        raise EvidenceUnavailable("git-checkout-head-record-malformed")
    return f"detached-head@{head}", checkout_transition_age(args, expected_branch=None)


def iso_epoch(value, task_id):
    if not isinstance(value, str):
        raise EvidenceUnavailable(f"op-direction-created-at-malformed:{task_id}")
    try:
        return int(dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError as error:
        raise EvidenceUnavailable(f"op-direction-created-at-malformed:{task_id}") from error


def branch_class(name, subject):
    value = f"{name} {subject}".lower()
    if re.search(r"serializ(?:e|ation)", value):
        return "serialization"
    if re.search(r"doctrine", value):
        return "doctrine"
    if re.search(r"tracker|bead[-_ ]?(?:close|closure|reconcile)", value):
        return "tracker"
    return None


def has_path_proof(task):
    evidence = []
    notes = task.get("notes")
    if isinstance(notes, str):
        evidence.append(notes)
    comments = task.get("comments", [])
    if comments is None:
        comments = []
    if not isinstance(comments, list):
        raise EvidenceUnavailable(f"op-direction-comments-malformed:{task['id']}")
    for comment in comments:
        if not isinstance(comment, dict) or not isinstance(comment.get("text"), str):
            raise EvidenceUnavailable(f"op-direction-comment-malformed:{task['id']}")
        evidence.append(comment["text"])
    path = re.compile(r"(?:^|[\s`'\"])(?:AGENTS\.md|(?:bin|docs|tests|\.agents)/[A-Za-z0-9._/-]+)")
    return any(path.search(item) for item in evidence)


try:
    run("git-repository", ["git", "rev-parse", "--git-dir"])
    run("git-base", ["git", "rev-parse", "--verify", f"{args.base}^{{commit}}"])
    checkout_state, checkout_epoch = current_checkout(args)
    refs = run(
        "git-branches",
        ["git", "for-each-ref", "--format=%(refname:short)\t%(committerdate:unix)\t%(subject)", "refs/heads/fm/*"],
    )
    debt = []
    if checkout_state is not None:
        checkout_age = max(0, args.now - checkout_epoch)
        if checkout_age > args.shift_seconds:
            debt.append(
                f"SERIALIZATION-DEBT: checkout={checkout_state} class=canonical-checkout "
                f"age_seconds={checkout_age} limit_seconds={args.shift_seconds} "
                f"expected_base={args.base}"
            )
    for line in refs.splitlines():
        fields = line.split("\t", 2)
        if len(fields) != 3 or not fields[0].startswith("fm/") or not fields[1].isdigit():
            raise EvidenceUnavailable("git-branch-record-malformed")
        name, updated, subject = fields
        classification = branch_class(name, subject)
        if classification is None:
            continue
        try:
            merged = subprocess.run(
                ["git", "merge-base", "--is-ancestor", name, args.base],
                cwd=args.project,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=timeout_seconds,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise EvidenceUnavailable(
                f"git-merge-evidence-unavailable:{name}:{type(error).__name__}"
            ) from error
        if merged.returncode == 0:
            continue
        if merged.returncode != 1:
            raise EvidenceUnavailable(f"git-merge-evidence-unavailable:{name}")
        age = max(0, args.now - int(updated))
        if age > args.shift_seconds:
            debt.append(
                f"SERIALIZATION-DEBT: branch={name} class={classification} age_seconds={age} "
                f"limit_seconds={args.shift_seconds} unmerged_into={args.base}"
            )

    task_cli = os.environ.get("FM_SERIALIZATION_TASK_CLI", "br")
    raw_tasks = run(
        "op-direction",
        [task_cli, "list", "--status", "open", "--label", "op-direction", "--limit", "100", "--json"],
    )
    try:
        payload = json.loads(raw_tasks)
    except json.JSONDecodeError as error:
        raise EvidenceUnavailable("op-direction-json-malformed") from error
    tasks = payload.get("issues") if isinstance(payload, dict) else payload
    if not isinstance(tasks, list):
        raise EvidenceUnavailable("op-direction-records-malformed")
    if len(tasks) >= 100:
        raise EvidenceUnavailable("op-direction-query-reached-bound")
    for task in tasks:
        if not isinstance(task, dict) or not isinstance(task.get("id"), str) or not isinstance(task.get("description"), str):
            raise EvidenceUnavailable("op-direction-task-malformed")
        description = task["description"]
        requires_path_proof = bool(
            re.search(r"encoding proof required|required file[- ]path proof|exact file path", description, re.IGNORECASE)
        )
        if not requires_path_proof:
            continue
        age = max(0, args.now - iso_epoch(task.get("created_at"), task["id"]))
        if age > args.shift_seconds and not has_path_proof(task):
            debt.append(
                f"SERIALIZATION-DEBT: bead={task['id']} class=op-direction-proof age_seconds={age} "
                f"limit_seconds={args.shift_seconds} reason=required-file-path-proof-missing"
            )
except EvidenceUnavailable as error:
    print(f"SERIALIZATION-DEBT-EVIDENCE-UNAVAILABLE: source=authoritative-records reason={error}")
    raise SystemExit(1)

if debt:
    print("\n".join(debt))
    raise SystemExit(1)
raise SystemExit(0)
PY
