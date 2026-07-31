#!/usr/bin/env bash
# Inventory active metadata without rewriting it, or rebuild derived WorkGraph state.
#
# Usage:
#   fm-workgraph-migrate.sh status
#   fm-workgraph-migrate.sh rebuild-state <workgraph.json>
#
# status classifies complete lease-backed WorkGraph metadata, legacy-exclusive
# metadata, and invalid partial bindings. It never rewrites active task metadata.
# rebuild-state atomically recreates one volatile projection from the sealed
# graph, durable lease/gate data, and persisted parallelism configuration.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,11{s/^#//;s/^ //;p;}' "$0"
}

die() {
  printf 'fm-workgraph-migrate: %s\n' "$*" >&2
  exit 1
}

COMMAND=${1:-}
[ "$COMMAND" = -h ] || [ "$COMMAND" = --help ] && { usage; exit 0; }
[ -n "$COMMAND" ] || { usage >&2; exit 2; }

case "$COMMAND" in
  status)
    [ "$#" -eq 1 ] || die 'usage: status'
    exec python3 - "$FM_ROOT" "$FM_HOME" "$STATE" "$DATA" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

root, home, state, data = map(Path, sys.argv[1:5])
safe_id = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
digest = re.compile(r"^[0-9a-f]{64}$")
positive = re.compile(r"^[1-9][0-9]*$")
digits = re.compile(r"^(?:0|[1-9][0-9]*)$")
required = {
    "workgraph_goal",
    "workgraph_slice",
    "workgraph_wave",
    "workgraph_graph",
    "workgraph_graph_sha256",
    "workgraph_contract_sha256",
    "workgraph_registry",
    "workgraph_registry_sha256",
    "workgraph_lease_id",
    "workgraph_fencing_token",
}


def canonical_file(path: Path) -> bytes:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ValueError("not a single-link regular file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
        raise ValueError("identity changed before open")
    if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
        opened.st_dev,
        opened.st_ino,
        opened.st_size,
        opened.st_mtime_ns,
    ):
        raise ValueError("identity changed during read")
    return b"".join(chunks)


def parse_meta(raw: bytes) -> dict[str, str]:
    text = raw.decode("utf-8", "strict")
    values: dict[str, str] = {}
    for line in text.splitlines():
        if not line or "=" not in line:
            raise ValueError("malformed metadata line")
        key, value = line.split("=", 1)
        if not key or key in values:
            raise ValueError("duplicate or empty metadata key")
        values[key] = value
    return values


def run(arguments: list[str]) -> bytes:
    environment = os.environ.copy()
    environment.update(
        {
            "FM_HOME": str(home),
            "FM_ROOT_OVERRIDE": str(root),
            "FM_STATE_OVERRIDE": str(state),
            "FM_DATA_OVERRIDE": str(data),
        }
    )
    result = subprocess.run(
        arguments,
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    if result.returncode != 0 or result.stderr:
        raise ValueError("bound command failed")
    return result.stdout


def classify(entry: os.DirEntry[str]) -> dict[str, str]:
    task_id = entry.name[:-5]
    result = {
        "task_id": task_id,
        "classification": "invalid",
        "reason": "invalid-workgraph-binding",
    }
    try:
        if safe_id.fullmatch(task_id) is None:
            result["reason"] = "unsafe-task-id"
            return result
        values = parse_meta(canonical_file(Path(entry.path)))
    except (OSError, UnicodeError, ValueError):
        result["reason"] = "nonregular-or-malformed-metadata"
        return result

    workgraph_keys = {key for key in values if key.startswith("workgraph_")}
    if not workgraph_keys:
        result["classification"] = "legacy-exclusive"
        result["reason"] = "missing-workgraph-contract"
        return result
    if workgraph_keys != required:
        result["reason"] = "partial-or-unknown-workgraph-binding"
        return result

    try:
        goal = values["workgraph_goal"]
        slice_id = values["workgraph_slice"]
        lease_id = values["workgraph_lease_id"]
        if any(safe_id.fullmatch(value) is None for value in (goal, slice_id, lease_id)):
            raise ValueError("unsafe identity")
        if digits.fullmatch(values["workgraph_wave"]) is None:
            raise ValueError("unsafe wave")
        if positive.fullmatch(values["workgraph_fencing_token"]) is None:
            raise ValueError("unsafe fencing token")
        if any(
            digest.fullmatch(values[key]) is None
            for key in (
                "workgraph_graph_sha256",
                "workgraph_contract_sha256",
                "workgraph_registry_sha256",
            )
        ):
            raise ValueError("unsafe digest")
        graph = Path(values["workgraph_graph"])
        registry = Path(values["workgraph_registry"])
        if not graph.is_absolute() or not registry.is_absolute():
            raise ValueError("relative binding")
        graph_bytes = canonical_file(graph)
        registry_bytes = canonical_file(registry)
        if hashlib.sha256(graph_bytes).hexdigest() != values["workgraph_graph_sha256"]:
            raise ValueError("graph digest changed")
        if hashlib.sha256(registry_bytes).hexdigest() != values["workgraph_registry_sha256"]:
            raise ValueError("registry digest changed")
        run([str(root / "bin/fm-workgraph.sh"), "registry", str(registry)])
        contract_bytes = run(
            [str(root / "bin/fm-workgraph.sh"), "contract", str(graph), slice_id]
        )
        if canonical_file(graph) != graph_bytes or canonical_file(registry) != registry_bytes:
            raise ValueError("binding changed during validation")
        if hashlib.sha256(contract_bytes).hexdigest() != values["workgraph_contract_sha256"]:
            raise ValueError("contract digest changed")
        contract = json.loads(contract_bytes)
        if contract["goal_id"] != goal or contract["slice_id"] != slice_id:
            raise ValueError("contract identity mismatch")
        if values.get("worktree") != contract["worktree"]:
            raise ValueError("worktree mismatch")
        lease = json.loads(
            run(
                [
                    str(root / "bin/fm-workgraph.sh"),
                    "inspect",
                    goal,
                    "--lease-id",
                    lease_id,
                ]
            )
        )
        token = values["workgraph_fencing_token"]
        if (
            lease.get("state") != "held"
            or lease.get("goal_id") != goal
            or lease.get("slice_id") != slice_id
            or lease.get("lease_id") != lease_id
            or lease.get("holder_id") != task_id
            or lease.get("holder_fencing_token") != token
            or lease.get("current_fencing_token") != token
        ):
            raise ValueError("held lease mismatch")
    except (KeyError, OSError, ValueError, json.JSONDecodeError):
        return result

    result.update(
        {
            "classification": "workgraph",
            "reason": "complete-held-binding",
            "goal_id": goal,
            "slice_id": slice_id,
            "worktree": values["worktree"],
        }
    )
    return result


try:
    state_stat = state.lstat()
except FileNotFoundError:
    entries: list[os.DirEntry[str]] = []
else:
    if not stat.S_ISDIR(state_stat.st_mode) or stat.S_ISLNK(state_stat.st_mode):
        raise SystemExit("fm-workgraph-migrate: state root is not an ordinary directory")
    with os.scandir(state) as iterator:
        entries = sorted(
            (entry for entry in iterator if entry.name.endswith(".meta")),
            key=lambda item: item.name.encode("utf-8", "surrogateescape"),
        )

tasks = [classify(entry) for entry in entries]
worktrees: dict[str, list[int]] = {}
for index, task in enumerate(tasks):
    if task["classification"] == "workgraph":
        worktrees.setdefault(task["worktree"], []).append(index)
for indexes in worktrees.values():
    if len(indexes) > 1:
        for index in indexes:
            tasks[index] = {
                "task_id": tasks[index]["task_id"],
                "classification": "invalid",
                "reason": "duplicate-worktree-owner",
            }

result = {
    "schema_version": "workgraph-migration-status/v1",
    "task_count": len(tasks),
    "workgraph_count": sum(task["classification"] == "workgraph" for task in tasks),
    "legacy_exclusive_count": sum(
        task["classification"] == "legacy-exclusive" for task in tasks
    ),
    "invalid_count": sum(task["classification"] == "invalid" for task in tasks),
    "tasks": tasks,
}
print(json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=True))
raise SystemExit(1 if result["invalid_count"] else 0)
PY
    ;;
  rebuild-state)
    [ "$#" -eq 2 ] && [ -n "$2" ] || die 'usage: rebuild-state <workgraph.json>'
    GRAPH=$2
    WORKGRAPH_STATUS=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$FM_ROOT/bin/fm-workgraph.sh" status "$GRAPH") \
      || die 'WorkGraph status could not be rebuilt from durable inputs'
    GOAL_ID=$(printf '%s\n' "$WORKGRAPH_STATUS" | awk -F= '
      /^goal_id=/ { count += 1; value = substr($0, index($0, "=") + 1) }
      END { if (count != 1 || value !~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/) exit 1; print value }
    ') || die 'validated WorkGraph did not expose one safe goal id'
    PARALLELISM_STATUS=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
      "$FM_ROOT/bin/fm-parallelism.sh" status --goal "$GOAL_ID") \
      || die 'parallelism status could not be rebuilt'
    CAPTURE=$(mktemp "${TMPDIR:-/tmp}/fm-workgraph-projection.XXXXXX") \
      || die 'cannot create projection capture'
    trap 'rm -f "$CAPTURE"' EXIT HUP INT TERM
    {
      printf 'projection_schema=workgraph-runtime-projection/v1\n'
      printf 'goal_id=%s\n' "$GOAL_ID"
      printf '[parallelism]\n%s\n' "$PARALLELISM_STATUS"
      printf '[workgraph]\n%s\n' "$WORKGRAPH_STATUS"
    } >"$CAPTURE" || die 'cannot capture projection'
    python3 - "$STATE" "$GOAL_ID" "$CAPTURE" <<'PY'
import hashlib
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

state = Path(sys.argv[1])
goal = sys.argv[2]
capture = Path(sys.argv[3])
state.mkdir(mode=0o700, parents=True, exist_ok=True)
state_stat = state.lstat()
if not stat.S_ISDIR(state_stat.st_mode) or stat.S_ISLNK(state_stat.st_mode):
    raise SystemExit("fm-workgraph-migrate: state root is not an ordinary directory")
root = state / "workgraphs"
root.mkdir(mode=0o700, exist_ok=True)
root_stat = root.lstat()
if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
    raise SystemExit("fm-workgraph-migrate: WorkGraph state root is not an ordinary directory")
directory = root / goal
directory.mkdir(mode=0o700, exist_ok=True)
directory_stat = directory.lstat()
if not stat.S_ISDIR(directory_stat.st_mode) or stat.S_ISLNK(directory_stat.st_mode):
    raise SystemExit("fm-workgraph-migrate: goal state root is not an ordinary directory")
target = directory / "projection.txt"
try:
    target_stat = target.lstat()
except FileNotFoundError:
    pass
else:
    if not stat.S_ISREG(target_stat.st_mode) or stat.S_ISLNK(target_stat.st_mode):
        raise SystemExit("fm-workgraph-migrate: projection target is not an ordinary file")
content = capture.read_bytes()
descriptor, temporary = tempfile.mkstemp(prefix=".projection.", dir=directory)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "wb", closefd=True) as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    descriptor = -1
    os.replace(temporary, target)
    directory_descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
except BaseException:
    if descriptor >= 0:
        try:
            os.close(descriptor)
        except OSError:
            pass
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
digest = hashlib.sha256(content).hexdigest()
print(json.dumps({
    "schema_version": "workgraph-state-rebuild/v1",
    "goal_id": goal,
    "projection": str(target.resolve()),
    "sha256": digest,
}, sort_keys=True, separators=(",", ":")))
PY
    ;;
  *)
    die "unknown command '$COMMAND'; use status or rebuild-state"
    ;;
esac
